using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
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
    private readonly WebApiServer _server;
    private string? _lastQrPayload;

    public MainWindow(
        ConfigService config,
        LogService log,
        SessionStore sessions,
        AgyRunnerService agy,
        TunnelService tunnel,
        WebApiServer server)
    {
        InitializeComponent();

        _config = config;
        _log = log;
        _sessions = sessions;
        _agy = agy;
        _tunnel = tunnel;
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
    }

    private void LoadConfigToUi()
    {
        var c = _config.Current;
        DeviceNameBox.Text = c.DeviceName;
        PortBox.Text = c.Port.ToString();
        AgyPathBox.Text = c.AgyExecutablePath;
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

        AgyStatusText.Text = _agy.IsAgyInstalled
            ? "Antigravity CLI: Ready (agy.exe detected)"
            : "Antigravity CLI: Not found (check path)";

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

    private void SaveSettings_Click(object sender, RoutedEventArgs e)
    {
        var c = _config.Current;
        c.DeviceName = string.IsNullOrWhiteSpace(DeviceNameBox.Text) ? Environment.MachineName : DeviceNameBox.Text.Trim();
        if (int.TryParse(PortBox.Text.Trim(), out var port) && port is >= 1024 and <= 65535)
        {
            c.Port = port;
        }
        c.AgyExecutablePath = AgyPathBox.Text.Trim();
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
            "WEP Host", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void BrowseWorkspace_Click(object sender, RoutedEventArgs e)
    {
        using var dlg = new Forms.FolderBrowserDialog
        {
            Description = "Select default Antigravity workspace folder",
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
