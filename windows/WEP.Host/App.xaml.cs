using System.Drawing;
using System.Threading;
using System.Windows;
using WEP.Host.Services;
using Forms = System.Windows.Forms;

namespace WEP.Host;

public partial class App : System.Windows.Application
{
    private const string SingleInstanceMutexName = @"Local\WEP_Host_SingleInstance_Mutex";
    private const string ActivateEventName = @"Local\WEP_Host_Activate_Event";

    private Mutex? _instanceMutex;
    private EventWaitHandle? _activateEvent;
    private CancellationTokenSource? _activateWatchCts;

    private ConfigService? _config;
    private LogService? _log;
    private SessionStore? _sessions;
    private WorkspaceService? _workspace;
    private AgyRunnerService? _agy;
    private TunnelService? _tunnel;
    private CursorExtensionService? _cursorExt;
    private WebApiServer? _server;

    private MainWindow? _mainWindow;
    private Forms.NotifyIcon? _trayIcon;
    private bool _isExiting;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _instanceMutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out var createdNew);
        if (!createdNew)
        {
            try
            {
                using var evt = EventWaitHandle.OpenExisting(ActivateEventName);
                evt.Set();
            }
            catch { }
            Shutdown();
            return;
        }

        ShutdownMode = ShutdownMode.OnExplicitShutdown;

        _activateEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ActivateEventName);
        _activateWatchCts = new CancellationTokenSource();
        StartActivateListener(_activateWatchCts.Token);

        _log = new LogService();
        _config = new ConfigService();
        _sessions = new SessionStore(_config);
        _workspace = new WorkspaceService(_config, _log);
        _agy = new AgyRunnerService(_config, _sessions, _log);
        _tunnel = new TunnelService(_config, _log);
        _cursorExt = new CursorExtensionService(_config, _log);
        _server = new WebApiServer(_config, _sessions, _workspace, _agy, _tunnel, _cursorExt, _log);

        _mainWindow = new MainWindow(_config, _log, _sessions, _agy, _tunnel, _cursorExt, _server);
        _mainWindow.Closing += MainWindow_Closing;

        SetupTrayIcon();

        var startMinimized = e.Args.Any(a => a.Equals("--minimized", StringComparison.OrdinalIgnoreCase));
        if (!startMinimized)
        {
            _mainWindow.Show();
        }

        _ = InitializeBackgroundServicesAsync();
    }

    private async Task InitializeBackgroundServicesAsync()
    {
        try
        {
            if (_server != null)
            {
                await _server.StartAsync();
            }

            if (_agy != null)
            {
                _ = Task.Run(() => _agy.GetModelsAsync(false));
            }

            if (_config?.Current.StartTunnelOnLaunch == true &&
                _config.Current.TunnelMode != "off" &&
                _tunnel != null)
            {
                _ = _tunnel.StartAsync();
            }
        }
        catch (Exception ex)
        {
            _log?.Error("Startup", $"Background initialization error: {ex.Message}");
        }
    }

    private void StartActivateListener(CancellationToken ct)
    {
        Task.Run(() =>
        {
            while (!ct.IsCancellationRequested && _activateEvent != null)
            {
                if (_activateEvent.WaitOne(500))
                {
                    Dispatcher.Invoke(ShowMainWindow);
                }
            }
        }, ct);
    }

    private void SetupTrayIcon()
    {
        Icon trayIco = SystemIcons.Application;
        try
        {
            var streamInfo = GetResourceStream(new Uri("pack://application:,,,/Assets/wep.ico"));
            if (streamInfo != null)
            {
                trayIco = new Icon(streamInfo.Stream);
            }
        }
        catch { }

        _trayIcon = new Forms.NotifyIcon
        {
            Icon = trayIco,
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
            _activateWatchCts?.Cancel();
            _tunnel?.Stop();
            if (_server != null) await _server.StopAsync();
        }
        catch { }

        if (_trayIcon != null)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
        }

        try
        {
            _activateEvent?.Dispose();
            _instanceMutex?.ReleaseMutex();
            _instanceMutex?.Dispose();
        }
        catch { }

        Shutdown();
    }
}
