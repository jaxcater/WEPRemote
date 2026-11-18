using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using WEP.Host.Models;

namespace WEP.Host.Services;

public sealed class CursorExtensionService
{
    private readonly ConfigService _config;
    private readonly LogService _log;

    public CursorExtensionService(ConfigService config, LogService log)
    {
        _config = config;
        _log = log;
    }

    public CursorLiveState GetLiveCursorState()
    {
        var state = new CursorLiveState();

        try
        {
            var procs = Process.GetProcessesByName("Cursor");
            state.ProcessCount = procs.Length;
            state.IsCursorRunning = procs.Length > 0;

            foreach (var p in procs)
            {
                try
                {
                    if (!string.IsNullOrWhiteSpace(p.MainWindowTitle))
                    {
                        state.ActiveWindowTitles.Add(p.MainWindowTitle.Trim());
                    }
                }
                catch { }
                finally { p.Dispose(); }
            }
        }
        catch { }

        var workspaces = ReadRecentCursorWorkspaces();
        state.OpenWorkspaces = workspaces;

        // Match running Cursor window title (e.g. "WEP.Host.csproj - CursorRemote - Cursor") to workspace folder name.
        foreach (var title in state.ActiveWindowTitles)
        {
            var matched = workspaces.FirstOrDefault(ws =>
            {
                var folderName = Path.GetFileName(ws.TrimEnd('\\', '/'));
                return !string.IsNullOrWhiteSpace(folderName) &&
                       title.Contains(folderName, StringComparison.OrdinalIgnoreCase);
            });
            if (!string.IsNullOrEmpty(matched))
            {
                state.ActiveWorkspace = matched;
                break;
            }
        }

        state.ActiveWorkspace ??= workspaces.FirstOrDefault();
        return state;
    }

    public List<string> ReadRecentCursorWorkspaces()
    {
        var list = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void TryAddFolderUri(string? uri)
        {
            if (string.IsNullOrWhiteSpace(uri)) return;
            var path = DecodeFileUri(uri);
            if (!string.IsNullOrWhiteSpace(path) && Directory.Exists(path) && seen.Add(path))
            {
                list.Add(path);
            }
        }

        // 1. Check workspaceStorage/*/workspace.json sorted by most recently modified
        try
        {
            var wsStorage = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Cursor", "User", "workspaceStorage");
            if (Directory.Exists(wsStorage))
            {
                var files = Directory.EnumerateFiles(wsStorage, "workspace.json", SearchOption.AllDirectories)
                    .Select(f => new FileInfo(f))
                    .OrderByDescending(fi => fi.LastWriteTimeUtc)
                    .Take(20);

                foreach (var fi in files)
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(File.ReadAllText(fi.FullName));
                        if (doc.RootElement.TryGetProperty("folder", out var folderProp))
                        {
                            TryAddFolderUri(folderProp.GetString());
                        }
                    }
                    catch { }
                }
            }
        }
        catch { }

        // 2. Check globalStorage/storage.json openedPathsList
        try
        {
            var storageJson = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Cursor", "User", "globalStorage", "storage.json");
            if (File.Exists(storageJson))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(storageJson));
                if (doc.RootElement.TryGetProperty("openedPathsList", out var opened) &&
                    opened.TryGetProperty("entries", out var entries) &&
                    entries.ValueKind == JsonValueKind.Array)
                {
                    foreach (var entry in entries.EnumerateArray())
                    {
                        if (entry.TryGetProperty("folderUri", out var fu))
                        {
                            TryAddFolderUri(fu.GetString());
                        }
                    }
                }
            }
        }
        catch { }

        return list.Take(15).ToList();
    }

    public async Task<(bool Ok, string Message)> OpenInCursorAsync(string path, int? line = null)
    {
        var cli = _config.Current.CursorCliPath;
        if (string.IsNullOrWhiteSpace(cli) || !File.Exists(cli))
        {
            return (false, "Cursor CLI not found on this PC.");
        }

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = cli.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) ? "cmd.exe" : cli,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            var target = Directory.Exists(path)
                ? $"\"{path}\""
                : (line.HasValue ? $"\"{path}:{line.Value}\"" : $"\"{path}\"");

            var cursorArgs = Directory.Exists(path) ? $"-r {target}" : $"-r -g {target}";

            if (cli.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase))
            {
                psi.Arguments = $"/c \"\"{cli}\" {cursorArgs}\"";
            }
            else
            {
                psi.Arguments = cursorArgs;
            }

            using var proc = Process.Start(psi);
            if (proc != null) await proc.WaitForExitAsync();
            _log.Info("Cursor", $"Opened in active Cursor window: {path}");
            return (true, $"Opened in Cursor: {path}");
        }
        catch (Exception ex)
        {
            _log.Warn("Cursor", $"Open in Cursor failed: {ex.Message}");
            return (false, ex.Message);
        }
    }

    public async Task<List<ExtensionItem>> ListAllExtensionsAsync(CancellationToken ct = default)
    {
        var items = new List<ExtensionItem>();
        items.AddRange(ReadCursorExtensions());
        items.AddRange(await ReadAntigravityPluginsAsync(ct));
        return items;
    }

    public List<ExtensionItem> ReadCursorExtensions()
    {
        var result = new List<ExtensionItem>();
        var extDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".cursor", "extensions");
        var extJson = Path.Combine(extDir, "extensions.json");
        if (!File.Exists(extJson)) return result;

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(extJson));
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return result;

            foreach (var el in doc.RootElement.EnumerateArray())
            {
                var id = el.TryGetProperty("identifier", out var idObj) && idObj.TryGetProperty("id", out var idStr)
                    ? (idStr.GetString() ?? string.Empty)
                    : string.Empty;
                if (string.IsNullOrWhiteSpace(id)) continue;

                var version = el.TryGetProperty("version", out var vEl) ? (vEl.GetString() ?? "") : "";
                var rel = el.TryGetProperty("relativeLocation", out var rEl) ? (rEl.GetString() ?? "") : "";
                var publisher = el.TryGetProperty("metadata", out var meta) && meta.TryGetProperty("publisherDisplayName", out var pubEl)
                    ? (pubEl.GetString() ?? "")
                    : id.Split('.').FirstOrDefault() ?? "";

                var installPath = string.IsNullOrWhiteSpace(rel) ? "" : Path.Combine(extDir, rel);
                var displayName = id;
                var description = string.Empty;

                if (!string.IsNullOrEmpty(installPath))
                {
                    var pkgJson = Path.Combine(installPath, "package.json");
                    if (File.Exists(pkgJson))
                    {
                        try
                        {
                            using var pkg = JsonDocument.Parse(File.ReadAllText(pkgJson));
                            if (pkg.RootElement.TryGetProperty("displayName", out var dn))
                            {
                                var val = dn.GetString();
                                if (!string.IsNullOrWhiteSpace(val) && !val.StartsWith('%')) displayName = val;
                            }
                            if (pkg.RootElement.TryGetProperty("description", out var desc))
                            {
                                var val = desc.GetString();
                                if (!string.IsNullOrWhiteSpace(val) && !val.StartsWith('%')) description = val;
                            }
                        }
                        catch { }
                    }
                }

                result.Add(new ExtensionItem
                {
                    Id = id,
                    Name = displayName,
                    Publisher = publisher,
                    Version = version,
                    Source = "cursor",
                    Enabled = true,
                    Description = description,
                    InstallPath = installPath
                });
            }
        }
        catch (Exception ex)
        {
            _log.Warn("Extensions", $"Could not read Cursor extensions.json: {ex.Message}");
        }

        return result.OrderBy(e => e.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    public async Task<List<ExtensionItem>> ReadAntigravityPluginsAsync(CancellationToken ct = default)
    {
        var items = new List<ExtensionItem>();
        var agy = _config.Current.AgyExecutablePath;
        if (!File.Exists(agy)) return items;

        try
        {
            var output = await RunCommandCaptureAsync(agy, "plugin list", ct);
            ExtensionItem? current = null;
            foreach (var raw in output.Split('\n'))
            {
                var line = raw.TrimEnd();
                if (line.StartsWith("- ", StringComparison.Ordinal))
                {
                    var body = line[2..].Trim();
                    var parenIdx = body.IndexOf('(');
                    var name = parenIdx > 0 ? body[..parenIdx].Trim() : body;
                    var inside = parenIdx > 0 ? body[(parenIdx + 1)..].TrimEnd(')') : "";
                    var parts = inside.Split(',', StringSplitOptions.TrimEntries);
                    var enabled = parts.Any(p => p.Equals("enabled", StringComparison.OrdinalIgnoreCase));
                    var version = parts.FirstOrDefault(p => p.Any(char.IsDigit)) ?? "";

                    current = new ExtensionItem
                    {
                        Id = name,
                        Name = name,
                        Publisher = "Antigravity",
                        Version = version,
                        Source = "antigravity",
                        Enabled = enabled
                    };
                    items.Add(current);
                }
                else if (current != null && line.TrimStart().StartsWith("Components:", StringComparison.OrdinalIgnoreCase))
                {
                    current.Description = line.Trim();
                }
            }
        }
        catch { }

        return items;
    }

    public async Task<(bool Ok, string Output)> ManageExtensionAsync(string action, string id, string source, CancellationToken ct = default)
    {
        if (source == "antigravity")
        {
            var agy = _config.Current.AgyExecutablePath;
            if (!File.Exists(agy)) return (false, "agy.exe not found.");
            var cmd = action switch
            {
                "enable" => $"plugin enable {id}",
                "disable" => $"plugin disable {id}",
                "install" => $"plugin install {id}",
                "uninstall" => $"plugin uninstall {id}",
                _ => $"plugin list"
            };
            var outText = await RunCommandCaptureAsync(agy, cmd, ct);
            _log.Info("Plugins", $"Antigravity {cmd}: {outText.Trim()}");
            return (true, outText.Trim());
        }

        var cursorCli = _config.Current.CursorCliPath;
        if (!File.Exists(cursorCli)) return (false, "Cursor CLI not found.");

        var flag = action switch
        {
            "install" => $"--install-extension \"{id}\"",
            "uninstall" => $"--uninstall-extension \"{id}\"",
            "update" => "--update-extensions",
            _ => "--list-extensions --show-versions"
        };

        var result = await RunCommandCaptureAsync("cmd.exe", $"/c \"\"{cursorCli}\" {flag}\"", ct);
        _log.Info("Extensions", $"Cursor {flag} completed.");
        return (true, result.Trim());
    }

    public List<CodexThreadSummary> ListCodexThreads(int limit = 25)
    {
        var list = new List<CodexThreadSummary>();
        var idxPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "session_index.jsonl");
        if (!File.Exists(idxPath)) return list;

        try
        {
            var lines = File.ReadAllLines(idxPath, Encoding.UTF8);
            for (int i = lines.Length - 1; i >= 0 && list.Count < limit; i--)
            {
                var line = lines[i].Trim();
                if (string.IsNullOrEmpty(line)) continue;
                try
                {
                    using var doc = JsonDocument.Parse(line);
                    var id = doc.RootElement.TryGetProperty("id", out var idEl) ? idEl.GetString() : null;
                    var title = doc.RootElement.TryGetProperty("thread_name", out var tEl) ? tEl.GetString() : "Codex Session";
                    var updated = doc.RootElement.TryGetProperty("updated_at", out var uEl) ? uEl.GetString() : "";
                    if (!string.IsNullOrWhiteSpace(id) && !list.Any(x => x.Id == id))
                    {
                        list.Add(new CodexThreadSummary
                        {
                            Id = id,
                            Title = string.IsNullOrWhiteSpace(title) ? "Codex Session" : title,
                            UpdatedAt = updated ?? ""
                        });
                    }
                }
                catch { }
            }
        }
        catch { }

        return list;
    }

    private static string? DecodeFileUri(string uri)
    {
        try
        {
            if (uri.StartsWith("file:///", StringComparison.OrdinalIgnoreCase))
            {
                var unescaped = Uri.UnescapeDataString(uri["file:///".Length..]);
                return unescaped.Replace('/', '\\');
            }
            if (Directory.Exists(uri)) return uri;
        }
        catch { }
        return null;
    }

    private static async Task<string> RunCommandCaptureAsync(string fileName, string args, CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = args,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        using var proc = Process.Start(psi);
        if (proc == null) return string.Empty;
        var stdout = await proc.StandardOutput.ReadToEndAsync(ct);
        var stderr = await proc.StandardError.ReadToEndAsync(ct);
        await proc.WaitForExitAsync(ct);
        return string.IsNullOrWhiteSpace(stdout) ? stderr : stdout;
    }
}
