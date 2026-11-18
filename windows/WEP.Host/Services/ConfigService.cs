using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Win32;
using WEP.Host.Models;

namespace WEP.Host.Services;

public sealed class ConfigService
{
    private const string RunRegistryKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string AppRegistryName = "WEPHost";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public string AppDataFolder { get; }
    public string ConfigFilePath { get; }
    public string SessionsFolder { get; }
    public string BinFolder { get; }

    public HostConfig Current { get; private set; } = new();

    public event Action<HostConfig>? ConfigChanged;

    public ConfigService()
    {
        AppDataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "WEP");
        SessionsFolder = Path.Combine(AppDataFolder, "sessions");
        BinFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "WEP", "bin");
        ConfigFilePath = Path.Combine(AppDataFolder, "config.json");

        Directory.CreateDirectory(AppDataFolder);
        Directory.CreateDirectory(SessionsFolder);
        Directory.CreateDirectory(BinFolder);

        Load();
    }

    public void Load()
    {
        if (File.Exists(ConfigFilePath))
        {
            try
            {
                var json = File.ReadAllText(ConfigFilePath);
                var loaded = JsonSerializer.Deserialize<HostConfig>(json, JsonOptions);
                if (loaded != null)
                {
                    Current = loaded;
                }
            }
            catch
            {
                Current = new HostConfig();
            }
        }

        var changed = false;
        if (string.IsNullOrWhiteSpace(Current.AuthToken))
        {
            Current.AuthToken = GenerateToken();
            changed = true;
        }

        if (string.IsNullOrWhiteSpace(Current.AgyExecutablePath) || !File.Exists(Current.AgyExecutablePath))
        {
            Current.AgyExecutablePath = DetectAgyPath();
            changed = true;
        }

        if (string.IsNullOrWhiteSpace(Current.DefaultWorkspace) || !Directory.Exists(Current.DefaultWorkspace))
        {
            Current.DefaultWorkspace = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            changed = true;
        }

        if (Current.PinnedWorkspaces.Count == 0)
        {
            var candidates = new[]
            {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Desktop"),
                Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            };
            foreach (var dir in candidates)
            {
                if (Directory.Exists(dir) && !Current.PinnedWorkspaces.Contains(dir, StringComparer.OrdinalIgnoreCase))
                {
                    Current.PinnedWorkspaces.Add(dir);
                }
            }
            changed = true;
        }

        if (changed || !File.Exists(ConfigFilePath))
        {
            Save();
        }

        ApplyKeepAwake(Current.KeepAwake);
        ApplyAutoStart(Current.AutoStartWithWindows);
    }

    public void Save()
    {
        var json = JsonSerializer.Serialize(Current, JsonOptions);
        File.WriteAllText(ConfigFilePath, json);
        ConfigChanged?.Invoke(Current);
    }

    public string RotateToken()
    {
        Current.AuthToken = GenerateToken();
        Save();
        return Current.AuthToken;
    }

    public void AddPinnedWorkspace(string path)
    {
        if (!Directory.Exists(path)) return;
        if (!Current.PinnedWorkspaces.Contains(path, StringComparer.OrdinalIgnoreCase))
        {
            Current.PinnedWorkspaces.Insert(0, path);
            if (Current.PinnedWorkspaces.Count > 15)
            {
                Current.PinnedWorkspaces.RemoveAt(Current.PinnedWorkspaces.Count - 1);
            }
            Save();
        }
    }

    public void ApplyKeepAwake(bool enabled)
    {
        try
        {
            if (enabled)
            {
                SetThreadExecutionState(EXECUTION_STATE.ES_CONTINUOUS | EXECUTION_STATE.ES_SYSTEM_REQUIRED);
            }
            else
            {
                SetThreadExecutionState(EXECUTION_STATE.ES_CONTINUOUS);
            }
        }
        catch
        {
            // Non-fatal if power state API is unavailable.
        }
    }

    public void ApplyAutoStart(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunRegistryKey, writable: true);
            if (key == null) return;

            if (enabled)
            {
                var exePath = Environment.ProcessPath;
                if (!string.IsNullOrWhiteSpace(exePath))
                {
                    key.SetValue(AppRegistryName, $"\"{exePath}\" --minimized");
                }
            }
            else
            {
                key.DeleteValue(AppRegistryName, throwOnMissingValue: false);
            }
        }
        catch
        {
            // Ignore registry permission errors.
        }
    }

    public static string DetectAgyPath()
    {
        var userGeminiAgy = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".gemini", "bin", "agy.exe");
        if (File.Exists(userGeminiAgy)) return userGeminiAgy;

        var pathEnv = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var dir in pathEnv.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(dir.Trim(), "agy.exe");
                if (File.Exists(candidate)) return candidate;
            }
            catch
            {
                // Skip invalid PATH entry.
            }
        }

        return userGeminiAgy;
    }

    private static string GenerateToken()
    {
        var bytes = RandomNumberGenerator.GetBytes(24);
        return "wep_" + Convert.ToHexString(bytes).ToLowerInvariant();
    }

    [Flags]
    private enum EXECUTION_STATE : uint
    {
        ES_AWAYMODE_REQUIRED = 0x00000040,
        ES_CONTINUOUS = 0x80000000,
        ES_DISPLAY_REQUIRED = 0x00000002,
        ES_SYSTEM_REQUIRED = 0x00000001
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern EXECUTION_STATE SetThreadExecutionState(EXECUTION_STATE esFlags);
}
