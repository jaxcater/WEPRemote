using System.Diagnostics;
using System.IO;
using System.Text;
using WEP.Host.Models;

namespace WEP.Host.Services;

public sealed class WorkspaceService
{
    private readonly ConfigService _config;
    private readonly LogService _log;

    public WorkspaceService(ConfigService config, LogService log)
    {
        _config = config;
        _log = log;
    }

    public bool IsPathAllowed(string fullPath)
    {
        var roots = _config.Current.AllowedRoots;
        if (roots == null || roots.Count == 0) return true;

        var normalizedTarget = Path.GetFullPath(fullPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        foreach (var root in roots)
        {
            if (string.IsNullOrWhiteSpace(root)) continue;
            var normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (normalizedTarget.Equals(normalizedRoot, StringComparison.OrdinalIgnoreCase) ||
                normalizedTarget.StartsWith(normalizedRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    public List<FsDriveItem> GetDrives()
    {
        var result = new List<FsDriveItem>();
        foreach (var drive in DriveInfo.GetDrives())
        {
            try
            {
                if (!drive.IsReady) continue;
                var rootPath = drive.RootDirectory.FullName;
                if (!IsPathAllowed(rootPath) && _config.Current.AllowedRoots.Count > 0)
                {
                    // Still allow browsing down to allowed roots via pinned workspaces.
                    continue;
                }

                result.Add(new FsDriveItem
                {
                    Name = drive.Name.TrimEnd('\\'),
                    Path = rootPath,
                    Label = string.IsNullOrWhiteSpace(drive.VolumeLabel) ? drive.DriveType.ToString() : drive.VolumeLabel,
                    TotalBytes = drive.TotalSize,
                    FreeBytes = drive.AvailableFreeSpace
                });
            }
            catch
            {
                // Ignore inaccessible drives.
            }
        }
        return result;
    }

    public FsListResponse ListDirectory(string? path, bool includeHidden = false)
    {
        var targetPath = string.IsNullOrWhiteSpace(path)
            ? _config.Current.DefaultWorkspace
            : Path.GetFullPath(path);

        if (!IsPathAllowed(targetPath))
        {
            throw new UnauthorizedAccessException($"Path is outside AllowedRoots: {targetPath}");
        }

        if (!Directory.Exists(targetPath))
        {
            throw new DirectoryNotFoundException($"Directory not found: {targetPath}");
        }

        var dirInfo = new DirectoryInfo(targetPath);
        var entries = new List<FsEntryItem>();

        foreach (var dir in dirInfo.EnumerateDirectories())
        {
            try
            {
                if (!includeHidden && (dir.Attributes & FileAttributes.Hidden) != 0 && !dir.Name.StartsWith(".github", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                entries.Add(new FsEntryItem
                {
                    Name = dir.Name,
                    Path = dir.FullName,
                    IsDirectory = true,
                    ModifiedAt = dir.LastWriteTimeUtc
                });
            }
            catch { }
        }

        foreach (var file in dirInfo.EnumerateFiles())
        {
            try
            {
                if (!includeHidden && (file.Attributes & FileAttributes.Hidden) != 0)
                {
                    continue;
                }
                entries.Add(new FsEntryItem
                {
                    Name = file.Name,
                    Path = file.FullName,
                    IsDirectory = false,
                    SizeBytes = file.Length,
                    ModifiedAt = file.LastWriteTimeUtc,
                    Extension = file.Extension
                });
            }
            catch { }
        }

        entries = entries
            .OrderByDescending(e => e.IsDirectory)
            .ThenBy(e => e.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();

        return new FsListResponse
        {
            CurrentPath = dirInfo.FullName,
            ParentPath = dirInfo.Parent?.FullName,
            Entries = entries
        };
    }

    public List<FsEntryItem> SearchFiles(string rootPath, string query, int maxResults = 60)
    {
        var fullRoot = Path.GetFullPath(rootPath);
        if (!IsPathAllowed(fullRoot)) throw new UnauthorizedAccessException("Path outside AllowedRoots.");
        if (!Directory.Exists(fullRoot)) throw new DirectoryNotFoundException(fullRoot);

        var results = new List<FsEntryItem>();
        var queue = new Queue<string>();
        queue.Enqueue(fullRoot);

        var skipDirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            ".git", "node_modules", "bin", "obj", ".vs", "DerivedData", "build", ".venv", "__pycache__"
        };

        while (queue.Count > 0 && results.Count < maxResults)
        {
            var current = queue.Dequeue();
            try
            {
                foreach (var dir in Directory.EnumerateDirectories(current))
                {
                    var name = Path.GetFileName(dir);
                    if (skipDirs.Contains(name)) continue;
                    if (string.IsNullOrWhiteSpace(query) || dir.Contains(query, StringComparison.OrdinalIgnoreCase))
                    {
                        results.Add(new FsEntryItem
                        {
                            Name = Path.GetRelativePath(fullRoot, dir),
                            Path = dir,
                            IsDirectory = true
                        });
                    }
                    queue.Enqueue(dir);
                    if (results.Count >= maxResults) break;
                }

                foreach (var file in Directory.EnumerateFiles(current))
                {
                    var rel = Path.GetRelativePath(fullRoot, file);
                    if (string.IsNullOrWhiteSpace(query) || rel.Contains(query, StringComparison.OrdinalIgnoreCase))
                    {
                        var fi = new FileInfo(file);
                        results.Add(new FsEntryItem
                        {
                            Name = rel,
                            Path = file,
                            IsDirectory = false,
                            SizeBytes = fi.Length,
                            Extension = fi.Extension
                        });
                    }
                    if (results.Count >= maxResults) break;
                }
            }
            catch { }
        }

        return results;
    }

    public FileContentResponse ReadFile(string path)
    {
        var fullPath = Path.GetFullPath(path);
        if (!IsPathAllowed(fullPath)) throw new UnauthorizedAccessException("Path outside AllowedRoots.");
        if (!File.Exists(fullPath)) throw new FileNotFoundException("File not found.", fullPath);

        var fi = new FileInfo(fullPath);
        const long MaxEditableBytes = 2 * 1024 * 1024; // 2 MB
        if (fi.Length > MaxEditableBytes)
        {
            throw new InvalidOperationException($"File exceeds 2 MB remote edit limit ({fi.Length} bytes).");
        }

        var bytes = File.ReadAllBytes(fullPath);
        var isBinary = bytes.Take(4096).Any(b => b == 0);
        var content = isBinary ? string.Empty : Encoding.UTF8.GetString(bytes);

        return new FileContentResponse
        {
            Path = fullPath,
            Name = fi.Name,
            Content = content,
            SizeBytes = fi.Length,
            ModifiedAt = fi.LastWriteTimeUtc,
            IsBinary = isBinary
        };
    }

    public FileContentResponse WriteFile(string path, string content)
    {
        var fullPath = Path.GetFullPath(path);
        if (!IsPathAllowed(fullPath)) throw new UnauthorizedAccessException("Path outside AllowedRoots.");

        var parent = Path.GetDirectoryName(fullPath);
        if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);

        File.WriteAllText(fullPath, content, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        _log.Info("Editor", $"Saved file: {fullPath}");

        var fi = new FileInfo(fullPath);
        return new FileContentResponse
        {
            Path = fullPath,
            Name = fi.Name,
            Content = content,
            SizeBytes = fi.Length,
            ModifiedAt = fi.LastWriteTimeUtc,
            IsBinary = false
        };
    }

    public void CreateItem(string path, bool isDirectory)
    {
        var fullPath = Path.GetFullPath(path);
        if (!IsPathAllowed(fullPath)) throw new UnauthorizedAccessException("Path outside AllowedRoots.");

        if (isDirectory)
        {
            Directory.CreateDirectory(fullPath);
            _log.Info("FS", $"Created folder: {fullPath}");
        }
        else
        {
            var parent = Path.GetDirectoryName(fullPath);
            if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
            if (!File.Exists(fullPath))
            {
                File.WriteAllText(fullPath, string.Empty, new UTF8Encoding(false));
            }
            _log.Info("FS", $"Created file: {fullPath}");
        }
    }

    public string RenameItem(string path, string newName)
    {
        var fullPath = Path.GetFullPath(path);
        if (!IsPathAllowed(fullPath)) throw new UnauthorizedAccessException("Path outside AllowedRoots.");

        var parent = Path.GetDirectoryName(fullPath) ?? throw new InvalidOperationException("Cannot rename root.");
        var destPath = Path.Combine(parent, newName);
        if (!IsPathAllowed(destPath)) throw new UnauthorizedAccessException("Destination outside AllowedRoots.");

        if (Directory.Exists(fullPath))
        {
            Directory.Move(fullPath, destPath);
        }
        else if (File.Exists(fullPath))
        {
            File.Move(fullPath, destPath);
        }
        else
        {
            throw new FileNotFoundException("Item not found.", fullPath);
        }

        _log.Info("FS", $"Renamed {fullPath} -> {destPath}");
        return destPath;
    }

    public void DeleteItem(string path)
    {
        var fullPath = Path.GetFullPath(path);
        if (!IsPathAllowed(fullPath)) throw new UnauthorizedAccessException("Path outside AllowedRoots.");

        if (Directory.Exists(fullPath))
        {
            Directory.Delete(fullPath, recursive: true);
        }
        else if (File.Exists(fullPath))
        {
            File.Delete(fullPath);
        }
        _log.Info("FS", $"Deleted: {fullPath}");
    }

    public async Task<GitStatusResponse> GetGitStatusAsync(string cwd, CancellationToken ct = default)
    {
        var fullCwd = Path.GetFullPath(cwd);
        if (!IsPathAllowed(fullCwd) || !Directory.Exists(fullCwd))
        {
            return new GitStatusResponse { IsGitRepo = false };
        }

        var check = await RunProcessAsync("git", "rev-parse --abbrev-ref HEAD", fullCwd, 10, ct);
        if (check.ExitCode != 0)
        {
            return new GitStatusResponse { IsGitRepo = false };
        }

        var status = await RunProcessAsync("git", "status --porcelain", fullCwd, 10, ct);
        var files = new List<GitChangedFile>();
        foreach (var line in status.Stdout.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            if (line.Length < 4) continue;
            var code = line[..2].Trim();
            var file = line[3..].Trim().Trim('"');
            files.Add(new GitChangedFile { Status = string.IsNullOrEmpty(code) ? "M" : code, Path = file });
        }

        return new GitStatusResponse
        {
            IsGitRepo = true,
            Branch = check.Stdout.Trim(),
            ChangedFiles = files
        };
    }

    public async Task<string> GetGitDiffAsync(string cwd, string? file, CancellationToken ct = default)
    {
        var fullCwd = Path.GetFullPath(cwd);
        if (!IsPathAllowed(fullCwd) || !Directory.Exists(fullCwd)) return string.Empty;

        var args = string.IsNullOrWhiteSpace(file)
            ? "diff"
            : $"diff -- \"{file.Replace("\"", "")}\"";
        var res = await RunProcessAsync("git", args, fullCwd, 15, ct);
        if (string.IsNullOrWhiteSpace(res.Stdout) && !string.IsNullOrWhiteSpace(file))
        {
            var untrackedPath = Path.Combine(fullCwd, file);
            if (File.Exists(untrackedPath))
            {
                var content = await File.ReadAllTextAsync(untrackedPath, ct);
                return $"--- /dev/null\n+++ b/{file}\n" +
                       string.Join('\n', content.Split('\n').Select(l => "+" + l));
            }
        }
        return res.Stdout;
    }

    public async Task<TerminalExecResponse> ExecuteShellAsync(TerminalExecRequest req, CancellationToken ct = default)
    {
        var cwd = string.IsNullOrWhiteSpace(req.Cwd) ? _config.Current.DefaultWorkspace : Path.GetFullPath(req.Cwd);
        if (!IsPathAllowed(cwd)) throw new UnauthorizedAccessException("Working directory outside AllowedRoots.");
        if (!Directory.Exists(cwd)) throw new DirectoryNotFoundException($"Directory not found: {cwd}");

        var encodedCommand = Convert.ToBase64String(Encoding.Unicode.GetBytes(req.Command));
        var res = await RunProcessAsync(
            "powershell.exe",
            $"-NoProfile -NonInteractive -EncodedCommand {encodedCommand}",
            cwd,
            Math.Clamp(req.TimeoutSeconds, 5, 300),
            ct);

        _log.Info("Terminal", $"[{cwd}] {req.Command} -> exit {res.ExitCode}");
        return res;
    }

    private static async Task<TerminalExecResponse> RunProcessAsync(
        string fileName, string arguments, string cwd, int timeoutSeconds, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            WorkingDirectory = cwd,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        using var proc = new Process { StartInfo = psi };
        proc.Start();

        var stdoutTask = proc.StandardOutput.ReadToEndAsync(ct);
        var stderrTask = proc.StandardError.ReadToEndAsync(ct);

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeoutCts.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));

        try
        {
            await proc.WaitForExitAsync(timeoutCts.Token);
        }
        catch (OperationCanceledException)
        {
            try { proc.Kill(entireProcessTree: true); } catch { }
            return new TerminalExecResponse
            {
                ExitCode = -1,
                Stdout = await SafeResult(stdoutTask),
                Stderr = (await SafeResult(stderrTask)) + "\n[Command timed out or cancelled]",
                Cwd = cwd,
                DurationSeconds = sw.Elapsed.TotalSeconds
            };
        }

        return new TerminalExecResponse
        {
            ExitCode = proc.ExitCode,
            Stdout = await stdoutTask,
            Stderr = await stderrTask,
            Cwd = cwd,
            DurationSeconds = sw.Elapsed.TotalSeconds
        };
    }

    private static async Task<string> SafeResult(Task<string> task)
    {
        try { return await task; } catch { return string.Empty; }
    }
}
