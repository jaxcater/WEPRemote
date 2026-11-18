using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using WEP.Host.Models;
using WEP.Host.Services;
using Forms = System.Windows.Forms;

namespace WEP.Host;

public partial class MainWindow : Window
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private readonly ConfigService _config;
    private readonly LogService _log;
    private readonly SessionStore _sessions;
    private readonly AgyRunnerService _agy;
    private readonly TunnelService _tunnel;
    private readonly CursorExtensionService _cursorExt;
    private readonly WebApiServer _server;

    private string? _lastQrPayload;
    private List<ExtensionItem> _loadedExtensions = new();

    public MainWindow(
        ConfigService config,
        LogService log,
        SessionStore sessions,
        AgyRunnerService agy,
        TunnelService tunnel,
        CursorExtensionService cursorExt,
        WebApiServer server)
    {
        InitializeComponent();

        _config = config;
        _log = log;
        _sessions = sessions;
        _agy = agy;
        _tunnel = tunnel;
        _cursorExt = cursorExt;
        _server = server;

        LoadConfigToUi();
        LoadExistingLogs();

        _log.OnLog += entry => Dispatcher.InvokeAsync(() =>
        {
            LogTextBox.AppendText(entry.Formatted + Environment.NewLine);
            LogTextBox.ScrollToEnd();
        });

        _tunnel.StateChanged += () => Dispatcher.InvokeAsync(RefreshStatusUi);
        _server.ClientsChanged += () => Dispatcher.InvokeAsync(RefreshStatusUi);
        _server.ServerStateChanged += () => Dispatcher.InvokeAsync(RefreshStatusUi);
        _agy.ActiveRunsChanged += () => Dispatcher.InvokeAsync(RefreshStatusUi);

        RefreshStatusUi();
        _ = RefreshCursorAndExtensionsAsync();
    }

    private void LoadConfigToUi()
    {
        var c = _config.Current;
        DeviceNameBox.Text = c.DeviceName;
        PortBox.Text = c.Port.ToString();
        AgyPathBox.Text = c.AgyExecutablePath;
        CodexPathBox.Text = c.CodexExecutablePath;
        CursorPathBox.Text = c.CursorCliPath;
        DefaultWorkspaceBox.Text = c.DefaultWorkspace;
        TokenBox.Text = c.AuthToken;
        CfTokenBox.Text = c.CloudflareTunnelToken;
        CustomDomainBox.Text = c.CustomPublicDomain;

        KeepAwakeCheck.IsChecked = c.KeepAwake;
        AutoStartCheck.IsChecked = c.AutoStartWithWindows;
        StartTunnelCheck.IsChecked = c.StartTunnelOnLaunch;
        TrayOnCloseCheck.IsChecked = c.MinimizeToTrayOnClose;
        SkipPermCheck.IsChecked = c.DefaultSkipPermissions;

        foreach (ComboBoxItem item in TunnelModeCombo.Items)
        {
            if (string.Equals(item.Tag?.ToString(), c.TunnelMode, StringComparison.OrdinalIgnoreCase))
            {
                TunnelModeCombo.SelectedItem = item;
                break;
            }
        }
        if (TunnelModeCombo.SelectedIndex < 0) TunnelModeCombo.SelectedIndex = 0;

        AllowedRootsList.Items.Clear();
        foreach (var r in c.AllowedRoots)
        {
            AllowedRootsList.Items.Add(r);
        }
    }

    private void LoadExistingLogs()
    {
        foreach (var entry in _log.Snapshot())
        {
            LogTextBox.AppendText(entry.Formatted + Environment.NewLine);
        }
        LogTextBox.ScrollToEnd();
    }

    private async Task RefreshCursorAndExtensionsAsync()
    {
        try
        {
            var live = await Task.Run(() => _cursorExt.GetLiveCursorState());
            var threads = await Task.Run(() => _cursorExt.ListCodexThreads(25));
            var exts = await _cursorExt.ListAllExtensionsAsync();

            await Dispatcher.InvokeAsync(() =>
            {
                HeaderCursorStatus.Text = live.IsCursorRunning
                    ? $"Cursor Live ({live.ProcessCount})"
                    : "Cursor Idle";
                CursorDot.Fill = live.IsCursorRunning
                    ? new SolidColorBrush(System.Windows.Media.Color.FromRgb(56, 189, 248))
                    : new SolidColorBrush(System.Windows.Media.Color.FromRgb(107, 114, 128));

                CursorLiveWorkspaceText.Text = string.IsNullOrWhiteSpace(live.ActiveWorkspace)
                    ? "No recent Cursor workspace detected"
                    : live.ActiveWorkspace;
                CursorWindowTitlesText.Text = live.ActiveWindowTitles.Count > 0
                    ? "Windows: " + string.Join(" | ", live.ActiveWindowTitles)
                    : "Cursor is not showing an active window title.";

                CursorWorkspacesList.Items.Clear();
                foreach (var ws in live.OpenWorkspaces)
                {
                    CursorWorkspacesList.Items.Add(ws);
                }

                CodexThreadsList.Items.Clear();
                foreach (var t in threads)
                {
                    CodexThreadsList.Items.Add($"[Codex] {t.Title}  ({t.Id[..Math.Min(8, t.Id.Length)]})");
                }

                _loadedExtensions = exts;
                ExtensionsListBox.Items.Clear();
                foreach (var ext in exts)
                {
                    var badge = ext.Source == "antigravity"
                        ? (ext.Enabled ? "[AGY Plugin • ON]" : "[AGY Plugin • OFF]")
                        : "[Cursor Ext]";
                    ExtensionsListBox.Items.Add($"{badge} {ext.Name}  ({ext.Id} v{ext.Version}) — {ext.Publisher}");
                }
            });
        }
        catch (Exception ex)
        {
            _log.Warn("UI", $"Refresh Cursor/Extensions error: {ex.Message}");
        }
    }

    private void RefreshStatusUi()
    {
        var lanUrl = _server.GetLanUrl();
        LanUrlBox.Text = lanUrl;

        TunnelUrlBox.Text = string.IsNullOrWhiteSpace(_tunnel.PublicUrl)
            ? (_tunnel.IsRunning || _tunnel.IsBusy ? _tunnel.Status : "Tunnel stopped (click Start Tunnel)")
            : _tunnel.PublicUrl;

        TunnelStatusText.Text = $"Tunnel: {_tunnel.Status}";
        ToggleTunnelBtn.Content = (_tunnel.IsRunning || _tunnel.IsBusy) ? "Stop Tunnel" : "Start Tunnel";

        if (_tunnel.DownloadPercent is int pct)
        {
            TunnelProgressBar.Visibility = Visibility.Visible;
            TunnelProgressBar.IsIndeterminate = false;
            TunnelProgressBar.Value = pct;
        }
        else if (_tunnel.IsBusy)
        {
            TunnelProgressBar.Visibility = Visibility.Visible;
            TunnelProgressBar.IsIndeterminate = true;
        }
        else
        {
            TunnelProgressBar.Visibility = Visibility.Collapsed;
            TunnelProgressBar.IsIndeterminate = false;
        }

        if (_server.IsRunning)
        {
            HeaderServerStatus.Text = $"Gateway Online (:{_config.Current.Port})";
            ServerDot.Fill = new SolidColorBrush(System.Windows.Media.Color.FromRgb(34, 197, 94));
        }
        else if (!string.IsNullOrEmpty(_server.LastError))
        {
            HeaderServerStatus.Text = $"Port {_config.Current.Port} Error";
            ServerDot.Fill = new SolidColorBrush(System.Windows.Media.Color.FromRgb(239, 68, 68));
        }
        else
        {
            HeaderServerStatus.Text = "Starting Gateway...";
            ServerDot.Fill = new SolidColorBrush(System.Windows.Media.Color.FromRgb(245, 158, 11));
        }

        HeaderClientsBadge.Text = $"{_server.ConnectedClientsCount} iOS Connected";
        ActiveRunsText.Text = $"Active Agent Runs: {_agy.ActiveRunCount}";

        EnginesSummaryText.Text =
            $"Antigravity: {(_agy.IsAgyInstalled ? "Ready" : "Missing")}  •  " +
            $"Codex: {(_agy.IsCodexInstalled ? "Ready" : "Missing")}";

        TokenBox.Text = _config.Current.AuthToken;

        try
        {
            var payloadJson = JsonSerializer.Serialize(_server.BuildPairingPayload(), JsonOptions);
            if (!string.Equals(payloadJson, _lastQrPayload, StringComparison.Ordinal))
            {
                _lastQrPayload = payloadJson;
                QrCodeImage.Source = QrCodeService.GenerateQrBitmap(payloadJson);
            }
        }
        catch { }
    }

    private async void ToggleTunnel_Click(object sender, RoutedEventArgs e)
    {
        if (_tunnel.IsRunning || _tunnel.IsBusy)
        {
            _tunnel.Stop();
        }
        else
        {
            await _tunnel.StartAsync();
        }
        RefreshStatusUi();
    }

    private async void RestartServer_Click(object sender, RoutedEventArgs e)
    {
        RestartServerBtn.IsEnabled = false;
        try
        {
            await _server.StopAsync();
            await _server.StartAsync();
        }
        finally
        {
            RestartServerBtn.IsEnabled = true;
            RefreshStatusUi();
        }
    }

    private async void RefreshCursorLive_Click(object sender, RoutedEventArgs e)
    {
        await RefreshCursorAndExtensionsAsync();
    }

    private void SyncCursorWorkspace_Click(object sender, RoutedEventArgs e)
    {
        var live = _cursorExt.GetLiveCursorState();
        if (!string.IsNullOrWhiteSpace(live.ActiveWorkspace))
        {
            _config.Current.DefaultWorkspace = live.ActiveWorkspace;
            _config.AddPinnedWorkspace(live.ActiveWorkspace);
            DefaultWorkspaceBox.Text = live.ActiveWorkspace;
            _config.Save();
            _log.Info("Cursor", $"Synced DefaultWorkspace to active Cursor folder: {live.ActiveWorkspace}");
        }
    }

    private async void OpenSelectedInCursor_Click(object sender, RoutedEventArgs e)
    {
        if (CursorWorkspacesList.SelectedItem is string path)
        {
            await _cursorExt.OpenInCursorAsync(path);
        }
    }

    private async void RefreshExtensions_Click(object sender, RoutedEventArgs e)
    {
        ExtStatusText.Text = "Refreshing...";
        await RefreshCursorAndExtensionsAsync();
        ExtStatusText.Text = $"{_loadedExtensions.Count} items loaded";
    }

    private async void InstallExtension_Click(object sender, RoutedEventArgs e)
    {
        var id = ExtensionInstallBox.Text.Trim();
        if (string.IsNullOrWhiteSpace(id)) return;

        InstallExtBtn.IsEnabled = false;
        ExtStatusText.Text = $"Installing {id}...";
        try
        {
            var (ok, output) = await _cursorExt.ManageExtensionAsync("install", id, "cursor");
            ExtStatusText.Text = ok ? $"Installed {id}" : output;
            ExtensionInstallBox.Clear();
            await RefreshCursorAndExtensionsAsync();
        }
        finally
        {
            InstallExtBtn.IsEnabled = true;
        }
    }

    private async void UpdateExtensions_Click(object sender, RoutedEventArgs e)
    {
        ExtStatusText.Text = "Updating Cursor extensions...";
        await _cursorExt.ManageExtensionAsync("update", "", "cursor");
        await RefreshCursorAndExtensionsAsync();
        ExtStatusText.Text = "Extensions updated";
    }

    private async void UninstallSelectedExtension_Click(object sender, RoutedEventArgs e)
    {
        var idx = ExtensionsListBox.SelectedIndex;
        if (idx < 0 || idx >= _loadedExtensions.Count) return;

        var ext = _loadedExtensions[idx];
        var confirm = System.Windows.MessageBox.Show(
            $"Uninstall {ext.Name} ({ext.Id})?",
            "Uninstall Extension", MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (confirm != MessageBoxResult.Yes) return;

        ExtStatusText.Text = $"Removing {ext.Id}...";
        await _cursorExt.ManageExtensionAsync("uninstall", ext.Id, ext.Source);
        await RefreshCursorAndExtensionsAsync();
        ExtStatusText.Text = $"Removed {ext.Id}";
    }

    private async void ToggleSelectedPlugin_Click(object sender, RoutedEventArgs e)
    {
        var idx = ExtensionsListBox.SelectedIndex;
        if (idx < 0 || idx >= _loadedExtensions.Count) return;

        var ext = _loadedExtensions[idx];
        if (ext.Source != "antigravity")
        {
            ExtStatusText.Text = "Toggle enable/disable applies to Antigravity plugins; use Uninstall for Cursor extensions.";
            return;
        }

        var action = ext.Enabled ? "disable" : "enable";
        ExtStatusText.Text = $"{action} {ext.Id}...";
        await _cursorExt.ManageExtensionAsync(action, ext.Id, "antigravity");
        await RefreshCursorAndExtensionsAsync();
        ExtStatusText.Text = $"Plugin {ext.Id} updated";
    }

    private void SaveSettings_Click(object sender, RoutedEventArgs e)
    {
        var c = _config.Current;
        c.DeviceName = string.IsNullOrWhiteSpace(DeviceNameBox.Text) ? Environment.MachineName : DeviceNameBox.Text.Trim();
        if (int.TryParse(PortBox.Text.Trim(), out var port) && port is >= 1024 and <= 65535)
        {
            c.Port = port;
        }
        c.AgyExecutablePath = AgyPathBox.Text.Trim();
        c.CodexExecutablePath = CodexPathBox.Text.Trim();
        c.CursorCliPath = CursorPathBox.Text.Trim();
        c.DefaultWorkspace = DefaultWorkspaceBox.Text.Trim();
        c.CloudflareTunnelToken = CfTokenBox.Text.Trim();
        c.CustomPublicDomain = CustomDomainBox.Text.Trim();

        if (TunnelModeCombo.SelectedItem is ComboBoxItem item && item.Tag is string mode)
        {
            c.TunnelMode = mode;
        }

        c.KeepAwake = KeepAwakeCheck.IsChecked == true;
        c.AutoStartWithWindows = AutoStartCheck.IsChecked == true;
        c.StartTunnelOnLaunch = StartTunnelCheck.IsChecked == true;
        c.MinimizeToTrayOnClose = TrayOnCloseCheck.IsChecked == true;
        c.DefaultSkipPermissions = SkipPermCheck.IsChecked == true;

        _config.Save();
        _config.ApplyKeepAwake(c.KeepAwake);
        _config.ApplyAutoStart(c.AutoStartWithWindows);

        _log.Info("Config", "Settings saved.");
        RefreshStatusUi();
        System.Windows.MessageBox.Show("Settings saved. Restart Gateway or Tunnel if you changed Port or Tunnel mode.",
            "WEP Studio Host", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void BrowseWorkspace_Click(object sender, RoutedEventArgs e)
    {
        using var dlg = new Forms.FolderBrowserDialog
        {
            Description = "Select default workspace folder",
            SelectedPath = DefaultWorkspaceBox.Text
        };
        if (dlg.ShowDialog() == Forms.DialogResult.OK)
        {
            DefaultWorkspaceBox.Text = dlg.SelectedPath;
        }
    }

    private void AddAllowedRoot_Click(object sender, RoutedEventArgs e)
    {
        using var dlg = new Forms.FolderBrowserDialog
        {
            Description = "Select folder to allow remote access"
        };
        if (dlg.ShowDialog() == Forms.DialogResult.OK)
        {
            if (!_config.Current.AllowedRoots.Contains(dlg.SelectedPath, StringComparer.OrdinalIgnoreCase))
            {
                _config.Current.AllowedRoots.Add(dlg.SelectedPath);
                _config.Save();
                AllowedRootsList.Items.Add(dlg.SelectedPath);
            }
        }
    }

    private void RemoveAllowedRoot_Click(object sender, RoutedEventArgs e)
    {
        if (AllowedRootsList.SelectedItem is string path)
        {
            _config.Current.AllowedRoots.Remove(path);
            _config.Save();
            AllowedRootsList.Items.Remove(path);
        }
    }

    private void CopyTunnelUrl_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(_tunnel.PublicUrl))
        {
            System.Windows.Clipboard.SetText(_tunnel.PublicUrl);
        }
    }

    private void CopyLanUrl_Click(object sender, RoutedEventArgs e)
    {
        System.Windows.Clipboard.SetText(_server.GetLanUrl());
    }

    private void CopyToken_Click(object sender, RoutedEventArgs e)
    {
        System.Windows.Clipboard.SetText(_config.Current.AuthToken);
    }

    private void RotateToken_Click(object sender, RoutedEventArgs e)
    {
        var confirm = System.Windows.MessageBox.Show(
            "Rotating the token will disconnect currently paired iOS devices until they re-pair. Continue?",
            "Rotate Access Token", MessageBoxButton.YesNo, MessageBoxImage.Warning);
        if (confirm != MessageBoxResult.Yes) return;

        _config.RotateToken();
        _log.Warn("Security", "Access token rotated.");
        RefreshStatusUi();
    }

    private void CopyPairingJson_Click(object sender, RoutedEventArgs e)
    {
        var json = JsonSerializer.Serialize(_server.BuildPairingPayload(), JsonOptions);
        System.Windows.Clipboard.SetText(json);
        _log.Info("Pairing", "Copied pairing JSON to clipboard.");
    }

    private void ClearLog_Click(object sender, RoutedEventArgs e)
    {
        LogTextBox.Clear();
    }

    private void MinimizeToTray_Click(object sender, RoutedEventArgs e)
    {
        Hide();
    }
}
