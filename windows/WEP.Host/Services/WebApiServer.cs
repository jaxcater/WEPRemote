using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using WEP.Host.Models;

namespace WEP.Host.Services;

public sealed class WebApiServer : IAsyncDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private readonly ConfigService _config;
    private readonly SessionStore _sessions;
    private readonly WorkspaceService _workspace;
    private readonly AgyRunnerService _agy;
    private readonly TunnelService _tunnel;
    private readonly CursorExtensionService _cursorExt;
    private readonly LogService _log;

    private readonly ConcurrentDictionary<string, WebSocket> _wsClients = new();
    private WebApplication? _app;
    private string? _cachedLanUrl;

    public bool IsRunning { get; private set; }
    public string? LastError { get; private set; }
    public int ConnectedClientsCount => _wsClients.Count;

    public event Action? ClientsChanged;
    public event Action? ServerStateChanged;

    public WebApiServer(
        ConfigService config,
        SessionStore sessions,
        WorkspaceService workspace,
        AgyRunnerService agy,
        TunnelService tunnel,
        CursorExtensionService cursorExt,
        LogService log)
    {
        _config = config;
        _sessions = sessions;
        _workspace = workspace;
        _agy = agy;
        _tunnel = tunnel;
        _cursorExt = cursorExt;
        _log = log;

        _agy.BroadcastEvent += BroadcastWsAsync;
        _tunnel.StateChanged += OnTunnelStateChanged;
    }

    private void OnTunnelStateChanged()
    {
        if (!IsRunning || _wsClients.IsEmpty) return;
        _ = BroadcastWsAsync("host.tunnel_updated", new
        {
            tunnelUrl = _tunnel.PublicUrl,
            tunnelStatus = _tunnel.Status,
            lanUrl = GetLanUrl()
        });
    }

    public async Task StartAsync()
    {
        if (IsRunning) return;
        LastError = null;

        try
        {
            await Task.Run(async () =>
            {
                RefreshLanUrl();
                var builder = WebApplication.CreateSlimBuilder();
                builder.Logging.ClearProviders();
                builder.WebHost.UseKestrel(opts =>
                {
                    opts.ListenAnyIP(_config.Current.Port);
                });

                var app = builder.Build();
                app.UseWebSockets(new WebSocketOptions
                {
                    KeepAliveInterval = TimeSpan.FromSeconds(20)
                });

                app.Use(async (ctx, next) =>
                {
                    ctx.Response.Headers["X-WEP-Host"] = "1.1.0";
                    if (ctx.Request.Path.Equals("/api/health", StringComparison.OrdinalIgnoreCase))
                    {
                        await next();
                        return;
                    }

                    if (!IsAuthorized(ctx))
                    {
                        ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
                        await ctx.Response.WriteAsJsonAsync(new { error = "Unauthorized. Invalid or missing WEP token." });
                        return;
                    }

                    await next();
                });

                MapRoutes(app);

                await app.StartAsync();
                _app = app;
                IsRunning = true;
            });

            ServerStateChanged?.Invoke();
            _log.Info("Server", $"WEP Host Gateway listening on http://0.0.0.0:{_config.Current.Port} (LAN: {GetLanUrl()})");
        }
        catch (Exception ex)
        {
            IsRunning = false;
            LastError = ex.Message;
            ServerStateChanged?.Invoke();
            _log.Error("Server", $"Failed to start Gateway on port {_config.Current.Port}: {ex.Message}");
        }
    }

    public async Task StopAsync()
    {
        if (!IsRunning || _app == null) return;

        foreach (var (_, ws) in _wsClients)
        {
            try
            {
                if (ws.State == WebSocketState.Open)
                {
                    await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "Server stopping", CancellationToken.None);
                }
            }
            catch { }
        }
        _wsClients.Clear();
        ClientsChanged?.Invoke();

        await _app.StopAsync();
        await _app.DisposeAsync();
        _app = null;
        IsRunning = false;
        ServerStateChanged?.Invoke();
        _log.Info("Server", "WEP Host Gateway stopped.");
    }

    public string GetLanUrl()
    {
        return _cachedLanUrl ?? RefreshLanUrl();
    }

    public string RefreshLanUrl()
    {
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                if (ni.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
                if (ni.Description.Contains("Virtual", StringComparison.OrdinalIgnoreCase) ||
                    ni.Description.Contains("Hyper-V", StringComparison.OrdinalIgnoreCase) ||
                    ni.Description.Contains("WSL", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                {
                    if (ua.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(ua.Address))
                    {
                        _cachedLanUrl = $"http://{ua.Address}:{_config.Current.Port}";
                        return _cachedLanUrl;
                    }
                }
            }
        }
        catch { }

        _cachedLanUrl = $"http://127.0.0.1:{_config.Current.Port}";
        return _cachedLanUrl;
    }

    public PairingPayload BuildPairingPayload()
    {
        return new PairingPayload
        {
            Name = _config.Current.DeviceName,
            TunnelUrl = _tunnel.PublicUrl,
            LanUrl = GetLanUrl(),
            Token = _config.Current.AuthToken,
            Version = "1.0.0"
        };
    }

    private void MapRoutes(WebApplication app)
    {
        app.MapGet("/api/health", (HttpContext ctx) =>
        {
            var authed = IsAuthorized(ctx);
            return Results.Ok(new
            {
                ok = true,
                authenticated = authed,
                name = _config.Current.DeviceName,
                version = "2.0.0",
                agyInstalled = _agy.IsAgyInstalled,
                codexInstalled = _agy.IsCodexInstalled,
                tunnelUrl = authed ? _tunnel.PublicUrl : null,
                lanUrl = authed ? GetLanUrl() : null
            });
        });

        app.MapGet("/api/info", async (CancellationToken ct) =>
        {
            var models = await _agy.GetModelsAsync(false, ct);
            var cursorLive = _cursorExt.GetLiveCursorState();
            var defaultWs = !string.IsNullOrWhiteSpace(cursorLive.ActiveWorkspace)
                ? cursorLive.ActiveWorkspace
                : _config.Current.DefaultWorkspace;

            return Results.Ok(new
            {
                deviceName = _config.Current.DeviceName,
                agyInstalled = _agy.IsAgyInstalled,
                codexInstalled = _agy.IsCodexInstalled,
                defaultWorkspace = defaultWs,
                pinnedWorkspaces = _config.Current.PinnedWorkspaces,
                tunnelUrl = _tunnel.PublicUrl,
                tunnelStatus = _tunnel.Status,
                lanUrl = GetLanUrl(),
                defaultSkipPermissions = _config.Current.DefaultSkipPermissions,
                cursorLive,
                models
            });
        });

        app.MapGet("/api/cursor/live", () => Results.Ok(_cursorExt.GetLiveCursorState()));

        app.MapPost("/api/cursor/open", async (CursorOpenRequest req) =>
        {
            if (string.IsNullOrWhiteSpace(req.Path)) return Results.BadRequest(new { error = "Path is required." });
            var (ok, msg) = await _cursorExt.OpenInCursorAsync(req.Path, req.Line);
            return ok ? Results.Ok(new { ok, message = msg }) : Results.BadRequest(new { error = msg });
        });

        app.MapGet("/api/extensions", async (CancellationToken ct) =>
        {
            var list = await _cursorExt.ListAllExtensionsAsync(ct);
            return Results.Ok(list);
        });

        app.MapPost("/api/extensions/install", async (ExtensionActionRequest req, CancellationToken ct) =>
        {
            var (ok, output) = await _cursorExt.ManageExtensionAsync("install", req.Id, req.Source, ct);
            return ok ? Results.Ok(new { ok, output }) : Results.BadRequest(new { error = output });
        });

        app.MapPost("/api/extensions/uninstall", async (ExtensionActionRequest req, CancellationToken ct) =>
        {
            var (ok, output) = await _cursorExt.ManageExtensionAsync("uninstall", req.Id, req.Source, ct);
            return ok ? Results.Ok(new { ok, output }) : Results.BadRequest(new { error = output });
        });

        app.MapPost("/api/extensions/update", async (CancellationToken ct) =>
        {
            var (ok, output) = await _cursorExt.ManageExtensionAsync("update", "", "cursor", ct);
            return ok ? Results.Ok(new { ok, output }) : Results.BadRequest(new { error = output });
        });

        app.MapPost("/api/extensions/plugin-toggle", async (ExtensionActionRequest req, CancellationToken ct) =>
        {
            var action = req.Enable == true ? "enable" : "disable";
            var (ok, output) = await _cursorExt.ManageExtensionAsync(action, req.Id, req.Source, ct);
            return ok ? Results.Ok(new { ok, output }) : Results.BadRequest(new { error = output });
        });

        app.MapGet("/api/codex/threads", () => Results.Ok(_cursorExt.ListCodexThreads()));

        app.MapPost("/api/codex/import", (CodexImportRequest req) =>
        {
            if (string.IsNullOrWhiteSpace(req.ThreadId)) return Results.BadRequest(new { error = "ThreadId required." });
            var existing = _sessions.ListAll().FirstOrDefault(s =>
                string.Equals(s.CodexThreadId, req.ThreadId, StringComparison.OrdinalIgnoreCase));
            if (existing != null) return Results.Ok(existing);

            var ws = string.IsNullOrWhiteSpace(req.WorkspacePath)
                ? (_cursorExt.GetLiveCursorState().ActiveWorkspace ?? _config.Current.DefaultWorkspace)
                : req.WorkspacePath;
            var session = _sessions.CreateOrGet(null, ws, req.Model ?? "gpt-6.1-sol", "auto");
            session.Engine = "codex";
            session.CodexThreadId = req.ThreadId;
            session.Effort = req.Effort ?? "medium";
            session.Title = string.IsNullOrWhiteSpace(req.Title) ? "Codex Session" : req.Title;
            _sessions.Save(session);
            return Results.Ok(session);
        });

        app.MapGet("/api/models", async (bool? refresh, CancellationToken ct) =>
        {
            var models = await _agy.GetModelsAsync(refresh ?? false, ct);
            return Results.Ok(models);
        });

        app.MapGet("/api/sessions", () => Results.Ok(_sessions.ListAll()));

        app.MapGet("/api/sessions/{id}", (string id) =>
        {
            var s = _sessions.Get(id);
            return s == null ? Results.NotFound(new { error = "Session not found" }) : Results.Ok(s);
        });

        app.MapPost("/api/sessions", (WsIncomingMessage req) =>
        {
            var ws = string.IsNullOrWhiteSpace(req.WorkspacePath)
                ? (_cursorExt.GetLiveCursorState().ActiveWorkspace ?? _config.Current.DefaultWorkspace)
                : req.WorkspacePath;
            var s = _sessions.CreateOrGet(
                req.SessionId,
                ws,
                req.Model ?? "gemini-4-hydrogen",
                req.Mode ?? "auto");
            if (!string.IsNullOrWhiteSpace(req.Engine)) s.Engine = req.Engine;
            if (!string.IsNullOrWhiteSpace(req.Effort)) s.Effort = req.Effort;
            _sessions.Save(s);
            return Results.Ok(s);
        });

        app.MapDelete("/api/sessions/{id}", (string id) =>
        {
            _agy.CancelSession(id);
            return _sessions.Delete(id) ? Results.Ok(new { deleted = true }) : Results.NotFound();
        });

        app.MapGet("/api/fs/drives", () => Results.Ok(_workspace.GetDrives()));

        app.MapGet("/api/fs/list", (string? path, bool? hidden) =>
        {
            try
            {
                return Results.Ok(_workspace.ListDirectory(path, hidden ?? false));
            }
            catch (UnauthorizedAccessException ex) { return Results.Json(new { error = ex.Message }, statusCode: 403); }
            catch (DirectoryNotFoundException ex) { return Results.NotFound(new { error = ex.Message }); }
            catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
        });

        app.MapGet("/api/fs/search", (string root, string? q) =>
        {
            try
            {
                return Results.Ok(_workspace.SearchFiles(root, q ?? string.Empty));
            }
            catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
        });

        app.MapGet("/api/fs/read", (string path) =>
        {
            try
            {
                return Results.Ok(_workspace.ReadFile(path));
            }
            catch (UnauthorizedAccessException ex) { return Results.Json(new { error = ex.Message }, statusCode: 403); }
            catch (FileNotFoundException ex) { return Results.NotFound(new { error = ex.Message }); }
            catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
        });

        app.MapPost("/api/fs/write", (FileWriteRequest req) =>
        {
            try
            {
                return Results.Ok(_workspace.WriteFile(req.Path, req.Content));
            }
            catch (UnauthorizedAccessException ex) { return Results.Json(new { error = ex.Message }, statusCode: 403); }
            catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
        });

        app.MapPost("/api/fs/create", (FsPathRequest req) =>
        {
            try
            {
                _workspace.CreateItem(req.Path, req.IsDirectory);
                return Results.Ok(new { ok = true, path = req.Path });
            }
            catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
        });

        app.MapPost("/api/fs/rename", (FsRenameRequest req) =>
        {
            try
            {
                var newPath = _workspace.RenameItem(req.Path, req.NewName);
                return Results.Ok(new { ok = true, path = newPath });
            }
            catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
        });

        app.MapDelete("/api/fs/item", (string path) =>
        {
            try
            {
                _workspace.DeleteItem(path);
                return Results.Ok(new { ok = true });
            }
            catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
        });

        app.MapPost("/api/workspace/pin", (FsPathRequest req) =>
        {
            _config.AddPinnedWorkspace(req.Path);
            return Results.Ok(new { pinnedWorkspaces = _config.Current.PinnedWorkspaces });
        });

        app.MapGet("/api/git/status", async (string cwd, CancellationToken ct) =>
        {
            try
            {
                return Results.Ok(await _workspace.GetGitStatusAsync(cwd, ct));
            }
            catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
        });

        app.MapGet("/api/git/diff", async (string cwd, string? file, CancellationToken ct) =>
        {
            try
            {
                var diff = await _workspace.GetGitDiffAsync(cwd, file, ct);
                return Results.Ok(new { diff });
            }
            catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
        });

        app.MapPost("/api/terminal/exec", async (TerminalExecRequest req, CancellationToken ct) =>
        {
            try
            {
                return Results.Ok(await _workspace.ExecuteShellAsync(req, ct));
            }
            catch (Exception ex) { return Results.BadRequest(new { error = ex.Message }); }
        });

        app.MapPost("/api/agent/start", async (WsIncomingMessage req) =>
        {
            if (string.IsNullOrWhiteSpace(req.Prompt))
            {
                return Results.BadRequest(new { error = "Prompt is required." });
            }

            var res = await _agy.StartTurnAsync(
                req.SessionId,
                req.Engine,
                req.WorkspacePath ?? _config.Current.DefaultWorkspace,
                req.Prompt,
                req.Model,
                req.Effort,
                req.Mode,
                req.SkipPermissions,
                req.AttachedFiles);
            return Results.Ok(new
            {
                accepted = true,
                sessionId = res.SessionId,
                turnId = res.TurnId,
                queued = res.Queued
            });
        });

        app.MapPost("/api/agent/cancel", (string sessionId, bool? clearQueue) =>
        {
            var cancelled = _agy.CancelSession(sessionId, clearQueue ?? false);
            return Results.Ok(new { cancelled });
        });

        app.MapPost("/api/agent/cancel-turn", (string sessionId, string turnId) =>
        {
            var cancelled = _agy.CancelTurn(sessionId, turnId);
            return Results.Ok(new { cancelled });
        });

        app.Map("/ws", async (HttpContext ctx) =>
        {
            if (!ctx.WebSockets.IsWebSocketRequest)
            {
                ctx.Response.StatusCode = StatusCodes.Status400BadRequest;
                return;
            }

            var ws = await ctx.WebSockets.AcceptWebSocketAsync();
            var clientId = Guid.NewGuid().ToString("N")[..8];
            _wsClients[clientId] = ws;
            ClientsChanged?.Invoke();
            _log.Info("WS", $"iOS client {clientId} connected ({ctx.Connection.RemoteIpAddress}).");

            try
            {
                await SendWsMessageAsync(ws, "host.connected", new
                {
                    clientId,
                    deviceName = _config.Current.DeviceName,
                    agyInstalled = _agy.IsAgyInstalled,
                    codexInstalled = _agy.IsCodexInstalled,
                    tunnelUrl = _tunnel.PublicUrl,
                    lanUrl = GetLanUrl()
                });

                await ReceiveLoopAsync(clientId, ws);
            }
            finally
            {
                _wsClients.TryRemove(clientId, out _);
                ClientsChanged?.Invoke();
                _log.Info("WS", $"iOS client {clientId} disconnected.");
                ws.Dispose();
            }
        });
    }

    private async Task ReceiveLoopAsync(string clientId, WebSocket ws)
    {
        var buffer = new byte[64 * 1024];
        var ms = new MemoryStream();

        while (ws.State == WebSocketState.Open)
        {
            ms.SetLength(0);
            WebSocketReceiveResult result;
            do
            {
                result = await ws.ReceiveAsync(buffer, CancellationToken.None);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "Closed by client", CancellationToken.None);
                    return;
                }
                ms.Write(buffer, 0, result.Count);
            } while (!result.EndOfMessage);

            var text = Encoding.UTF8.GetString(ms.ToArray());
            await HandleClientMessageAsync(ws, text);
        }
    }

    private async Task HandleClientMessageAsync(WebSocket ws, string json)
    {
        try
        {
            var msg = JsonSerializer.Deserialize<WsIncomingMessage>(json, JsonOptions);
            if (msg == null) return;

            switch (msg.Type)
            {
                case "ping":
                    await SendWsMessageAsync(ws, "pong", new { ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() });
                    break;

                case "agent.start":
                    if (!string.IsNullOrWhiteSpace(msg.Prompt))
                    {
                        await _agy.StartTurnAsync(
                            msg.SessionId,
                            msg.Engine,
                            msg.WorkspacePath ?? _config.Current.DefaultWorkspace,
                            msg.Prompt,
                            msg.Model,
                            msg.Effort,
                            msg.Mode,
                            msg.SkipPermissions,
                            msg.AttachedFiles);
                    }
                    break;

                case "agent.cancel":
                    if (!string.IsNullOrWhiteSpace(msg.SessionId))
                    {
                        _agy.CancelSession(msg.SessionId, msg.ClearQueue ?? false);
                    }
                    break;

                case "agent.cancel_turn":
                    if (!string.IsNullOrWhiteSpace(msg.SessionId) && !string.IsNullOrWhiteSpace(msg.TurnId))
                    {
                        _agy.CancelTurn(msg.SessionId, msg.TurnId);
                    }
                    break;

                case "terminal.exec":
                    if (!string.IsNullOrWhiteSpace(msg.Command))
                    {
                        var res = await _workspace.ExecuteShellAsync(new TerminalExecRequest
                        {
                            Cwd = msg.Cwd ?? _config.Current.DefaultWorkspace,
                            Command = msg.Command
                        });
                        await SendWsMessageAsync(ws, "terminal.result", res);
                    }
                    break;
            }
        }
        catch (Exception ex)
        {
            await SendWsMessageAsync(ws, "host.error", new { message = ex.Message });
        }
    }

    private async Task BroadcastWsAsync(string type, object payload)
    {
        var envelope = JsonSerializer.Serialize(new { type, payload }, JsonOptions);
        var bytes = Encoding.UTF8.GetBytes(envelope);
        var segment = new ArraySegment<byte>(bytes);

        foreach (var (id, ws) in _wsClients)
        {
            if (ws.State != WebSocketState.Open) continue;
            try
            {
                await ws.SendAsync(segment, WebSocketMessageType.Text, true, CancellationToken.None);
            }
            catch
            {
                _wsClients.TryRemove(id, out _);
            }
        }
    }

    private static async Task SendWsMessageAsync(WebSocket ws, string type, object payload)
    {
        if (ws.State != WebSocketState.Open) return;
        var envelope = JsonSerializer.Serialize(new { type, payload }, JsonOptions);
        var bytes = Encoding.UTF8.GetBytes(envelope);
        await ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None);
    }

    private bool IsAuthorized(HttpContext ctx)
    {
        var expected = _config.Current.AuthToken;
        if (string.IsNullOrEmpty(expected)) return false;

        string? provided = null;
        if (ctx.Request.Headers.TryGetValue("Authorization", out var authHeader))
        {
            var raw = authHeader.ToString();
            if (raw.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            {
                provided = raw["Bearer ".Length..].Trim();
            }
        }
        else if (ctx.Request.Query.TryGetValue("token", out var tokenQuery))
        {
            provided = tokenQuery.ToString();
        }

        if (string.IsNullOrEmpty(provided)) return false;

        var a = Encoding.UTF8.GetBytes(expected);
        var b = Encoding.UTF8.GetBytes(provided);
        return a.Length == b.Length && CryptographicOperations.FixedTimeEquals(a, b);
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
    }
}
