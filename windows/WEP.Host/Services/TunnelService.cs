using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text.RegularExpressions;

namespace WEP.Host.Services;

public sealed partial class TunnelService : IDisposable
{
    private const string CloudflaredDownloadUrl =
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe";

    private readonly ConfigService _config;
    private readonly LogService _log;
    private Process? _tunnelProcess;
    private CancellationTokenSource? _tunnelCts;

    public string? PublicUrl { get; private set; }
    public string Status { get; private set; } = "Stopped";
    public bool IsRunning => _tunnelProcess is { HasExited: false };

    public event Action? StateChanged;

    public TunnelService(ConfigService config, LogService log)
    {
        _config = config;
        _log = log;
    }

    public string? FindCloudflaredPath()
    {
        var localBin = Path.Combine(_config.BinFolder, "cloudflared.exe");
        if (File.Exists(localBin)) return localBin;

        var pathEnv = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var dir in pathEnv.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(dir.Trim(), "cloudflared.exe");
                if (File.Exists(candidate)) return candidate;
            }
            catch { }
        }
        return null;
    }

    public async Task<string> EnsureCloudflaredAsync(IProgress<string>? progress = null, CancellationToken ct = default)
    {
        var existing = FindCloudflaredPath();
        if (!string.IsNullOrEmpty(existing)) return existing;

        var destPath = Path.Combine(_config.BinFolder, "cloudflared.exe");
        Status = "Downloading cloudflared...";
        StateChanged?.Invoke();
        progress?.Report("Downloading cloudflared.exe from Cloudflare GitHub releases...");
        _log.Info("Tunnel", "Downloading cloudflared-windows-amd64.exe...");

        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        using var resp = await http.GetAsync(CloudflaredDownloadUrl, HttpCompletionOption.ResponseHeadersRead, ct);
        resp.EnsureSuccessStatusCode();

        var totalBytes = resp.Content.Headers.ContentLength;
        await using var stream = await resp.Content.ReadAsStreamAsync(ct);
        await using var fs = new FileStream(destPath + ".tmp", FileMode.Create, FileAccess.Write, FileShare.None);

        var buffer = new byte[81920];
        long downloaded = 0;
        int read;
        while ((read = await stream.ReadAsync(buffer, ct)) > 0)
        {
            await fs.WriteAsync(buffer.AsMemory(0, read), ct);
            downloaded += read;
            if (totalBytes.HasValue && totalBytes.Value > 0)
            {
                var pct = (int)(downloaded * 100 / totalBytes.Value);
                Status = $"Downloading cloudflared ({pct}%)...";
                StateChanged?.Invoke();
            }
        }
        await fs.FlushAsync(ct);
        fs.Close();

        File.Move(destPath + ".tmp", destPath, overwrite: true);
        _log.Info("Tunnel", $"Downloaded cloudflared.exe to {destPath}");
        return destPath;
    }

    public async Task StartAsync(CancellationToken ct = default)
    {
        if (IsRunning) return;

        var mode = _config.Current.TunnelMode;
        if (mode == "off")
        {
            Status = "Disabled (LAN only)";
            PublicUrl = null;
            StateChanged?.Invoke();
            return;
        }

        try
        {
            var exePath = await EnsureCloudflaredAsync(null, ct);
            _tunnelCts = new CancellationTokenSource();

            var psi = new ProcessStartInfo
            {
                FileName = exePath,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            if (mode == "named" && !string.IsNullOrWhiteSpace(_config.Current.CloudflareTunnelToken))
            {
                psi.ArgumentList.Add("tunnel");
                psi.ArgumentList.Add("--no-autoupdate");
                psi.ArgumentList.Add("run");
                psi.ArgumentList.Add("--token");
                psi.ArgumentList.Add(_config.Current.CloudflareTunnelToken.Trim());
                PublicUrl = string.IsNullOrWhiteSpace(_config.Current.CustomPublicDomain)
                    ? null
                    : EnsureHttps(_config.Current.CustomPublicDomain);
                Status = "Connecting Named Tunnel...";
            }
            else
            {
                psi.ArgumentList.Add("tunnel");
                psi.ArgumentList.Add("--no-autoupdate");
                psi.ArgumentList.Add("--url");
                psi.ArgumentList.Add($"http://127.0.0.1:{_config.Current.Port}");
                PublicUrl = null;
                Status = "Opening Quick Tunnel...";
            }

            StateChanged?.Invoke();

            _tunnelProcess = new Process { StartInfo = psi, EnableRaisingEvents = true };
            _tunnelProcess.Exited += (_, _) =>
            {
                PublicUrl = null;
                Status = "Stopped";
                StateChanged?.Invoke();
            };

            _tunnelProcess.Start();
            _log.Info("Tunnel", $"Started cloudflared ({mode}) targeting port {_config.Current.Port}");

            _ = MonitorOutputAsync(_tunnelProcess.StandardError, _tunnelCts.Token);
            _ = MonitorOutputAsync(_tunnelProcess.StandardOutput, _tunnelCts.Token);
        }
        catch (Exception ex)
        {
            Status = $"Error: {ex.Message}";
            PublicUrl = null;
            StateChanged?.Invoke();
            _log.Error("Tunnel", $"Failed to start tunnel: {ex.Message}");
        }
    }

    public void Stop()
    {
        try
        {
            _tunnelCts?.Cancel();
            if (_tunnelProcess is { HasExited: false })
            {
                _tunnelProcess.Kill(entireProcessTree: true);
            }
        }
        catch { }
        finally
        {
            _tunnelProcess?.Dispose();
            _tunnelProcess = null;
            PublicUrl = null;
            Status = "Stopped";
            StateChanged?.Invoke();
            _log.Info("Tunnel", "Cloudflare Tunnel stopped.");
        }
    }

    private async Task MonitorOutputAsync(StreamReader reader, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var line = await reader.ReadLineAsync(ct);
                if (line == null) break;

                var match = TryCloudflareRegex().Match(line);
                if (match.Success)
                {
                    PublicUrl = match.Value;
                    Status = "Connected (Cloudflare Quick Tunnel)";
                    StateChanged?.Invoke();
                    _log.Info("Tunnel", $"Public Tunnel URL ready: {PublicUrl}");
                }
                else if (line.Contains("Registered tunnel connection", StringComparison.OrdinalIgnoreCase))
                {
                    Status = "Connected (Cloudflare Named Tunnel)";
                    StateChanged?.Invoke();
                    _log.Info("Tunnel", "Named tunnel edge connection registered.");
                }
            }
        }
        catch { }
    }

    private static string EnsureHttps(string domain)
    {
        var d = domain.Trim().TrimEnd('/');
        return d.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
               d.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
            ? d
            : $"https://{d}";
    }

    [GeneratedRegex(@"https://[a-zA-Z0-9\-]+\.trycloudflare\.com", RegexOptions.Compiled)]
    private static partial Regex TryCloudflareRegex();

    public void Dispose() => Stop();
}
