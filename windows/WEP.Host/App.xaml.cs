using System.Drawing;
using System.Windows;
using WEP.Host.Services;
using Forms = System.Windows.Forms;

namespace WEP.Host;

public partial class App : System.Windows.Application
{
    private ConfigService? _config;
    private LogService? _log;
    private SessionStore? _sessions;
    private WorkspaceService? _workspace;
    private AgyRunnerService? _agy;
    private TunnelService? _tunnel;
    private WebApiServer? _server;

    private MainWindow? _mainWindow;
    private Forms.NotifyIcon? _trayIcon;
    private bool _isExiting;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        ShutdownMode = ShutdownMode.OnExplicitShutdown;

        _log = new LogService();
        _config = new ConfigService();
        _sessions = new SessionStore(_config);
        _workspace = new WorkspaceService(_config, _log);
        _agy = new AgyRunnerService(_config, _sessions, _log);
        _tunnel = new TunnelService(_config, _log);
        _server = new WebApiServer(_config, _sessions, _workspace, _agy, _tunnel, _log);

        _mainWindow = new MainWindow(_config, _log, _sessions, _agy, _tunnel, _server);
        _mainWindow.Closing += MainWindow_Closing;

        SetupTrayIcon();

        var startMinimized = e.Args.Any(a => a.Equals("--minimized", StringComparison.OrdinalIgnoreCase));
        if (!startMinimized)
        {
            _mainWindow.Show();
        }

        await _server.StartAsync();

        if (_config.Current.StartTunnelOnLaunch && _config.Current.TunnelMode != "off")
        {
            _ = _tunnel.StartAsync();
        }
    }

    private void SetupTrayIcon()
    {
        _trayIcon = new Forms.NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "WEP Host — Antigravity Remote Gateway",
            Visible = true
        };

        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open WEP Control Center", null, (_, _) => ShowMainWindow());
        menu.Items.Add("Copy Pairing Token", null, (_, _) =>
        {
            if (_config != null) System.Windows.Clipboard.SetText(_config.Current.AuthToken);
        });
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit WEP Host", null, async (_, _) => await ExitApplicationAsync());

        _trayIcon.ContextMenuStrip = menu;
        _trayIcon.DoubleClick += (_, _) => ShowMainWindow();
    }

    private void ShowMainWindow()
    {
        if (_mainWindow == null) return;
        _mainWindow.Show();
        if (_mainWindow.WindowState == WindowState.Minimized)
        {
            _mainWindow.WindowState = WindowState.Normal;
        }
        _mainWindow.Activate();
    }

    private void MainWindow_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (!_isExiting && _config?.Current.MinimizeToTrayOnClose == true)
        {
            e.Cancel = true;
            _mainWindow?.Hide();
            _trayIcon?.ShowBalloonTip(2000, "WEP Host Running",
                "Antigravity remote gateway continues running in the system tray.",
                Forms.ToolTipIcon.Info);
            return;
        }

        _ = ExitApplicationAsync();
    }

    public async Task ExitApplicationAsync()
    {
        if (_isExiting) return;
        _isExiting = true;

        try
        {
            _tunnel?.Stop();
            if (_server != null) await _server.StopAsync();
        }
        catch { }

        if (_trayIcon != null)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
        }

        Shutdown();
    }
}
