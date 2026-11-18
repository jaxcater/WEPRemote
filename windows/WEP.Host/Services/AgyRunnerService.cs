using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using WEP.Host.Models;

namespace WEP.Host.Services;

public sealed class AgyRunnerService
{
    private static readonly string[] EffortOrder = { "low", "medium", "high", "xhigh", "max", "ultra" };

    private readonly ConfigService _config;
    private readonly SessionStore _sessions;
    private readonly LogService _log;
    private readonly ConcurrentDictionary<string, Process> _activeProcesses = new();
    private readonly ConcurrentDictionary<string, string> _activeTurnIds = new();
    private readonly ConcurrentDictionary<string, ConcurrentQueue<QueuedTurnItem>> _sessionQueues = new();
    private readonly ConcurrentDictionary<string, SemaphoreSlim> _sessionGates = new();
    private List<AiModelOption> _cachedModels = DefaultModels();
    private bool _modelsLoaded;

    public sealed record TurnEnqueueResult(string SessionId, string TurnId, bool Queued);

    private sealed record QueuedTurnItem(
        SessionTurn Turn,
        string Engine,
        string Model,
        string Effort,
        string Mode,
        bool SkipPermissions);

    public event Func<string, object, Task>? BroadcastEvent;
    public event Action? ActiveRunsChanged;

    public int ActiveRunCount => _activeProcesses.Count;
    public bool IsAgyInstalled => File.Exists(_config.Current.AgyExecutablePath);
    public bool IsCodexInstalled => !string.IsNullOrWhiteSpace(_config.Current.CodexExecutablePath) &&
                                    File.Exists(_config.Current.CodexExecutablePath);

    public AgyRunnerService(ConfigService config, SessionStore sessions, LogService log)
    {
        _config = config;
        _sessions = sessions;
        _log = log;
    }

    public async Task<List<AiModelOption>> GetModelsAsync(bool forceRefresh = false, CancellationToken ct = default)
    {
        if (!forceRefresh && _modelsLoaded) return _cachedModels;

        var combined = new List<AiModelOption>();

        // 1. Antigravity models grouped by base model + separated efforts
        var agyModels = await LoadAntigravityModelsAsync(ct);
        combined.AddRange(agyModels.Count > 0 ? agyModels : DefaultAntigravityModels());

        // 2. Codex models from ~/.codex/models_cache.json
        var codexModels = LoadCodexModels();
        combined.AddRange(codexModels.Count > 0 ? codexModels : DefaultCodexModels());

        _cachedModels = combined;
        _modelsLoaded = true;
        return _cachedModels;
    }

    private async Task<List<AiModelOption>> LoadAntigravityModelsAsync(CancellationToken ct)
    {
        if (!IsAgyInstalled) return new List<AiModelOption>();

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = _config.Current.AgyExecutablePath,
                Arguments = "models",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8
            };
            using var proc = Process.Start(psi);
            if (proc == null) return new List<AiModelOption>();

            var output = await proc.StandardOutput.ReadToEndAsync(ct);
            await proc.WaitForExitAsync(ct);

            var grouped = new Dictionary<string, AiModelOption>(StringComparer.OrdinalIgnoreCase);

            foreach (var rawLine in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                var line = rawLine.Trim();
                if (line.StartsWith("Fetching", StringComparison.OrdinalIgnoreCase)) continue;
                var parts = line.Split('\t', 2);
                if (parts.Length != 2 || string.IsNullOrWhiteSpace(parts[0])) continue;

                var rawId = parts[0].Trim();
                var rawDisplay = parts[1].Trim();

                var (baseId, effort) = SplitEffortSuffix(rawId);
                var cleanDisplay = StripEffortDisplay(rawDisplay);

                if (!grouped.TryGetValue(baseId, out var option))
                {
                    option = new AiModelOption
                    {
                        Id = baseId,
                        BaseModel = baseId,
                        DisplayName = cleanDisplay,
                        Engine = "antigravity",
                        DefaultEffort = effort ?? "high",
                        SupportedEfforts = new List<string>(),
                        RawVariantIds = new List<string>()
                    };
                    grouped[baseId] = option;
                }

                option.RawVariantIds.Add(rawId);
                if (effort != null && !option.SupportedEfforts.Contains(effort))
                {
                    option.SupportedEfforts.Add(effort);
                }
            }

            foreach (var m in grouped.Values)
            {
                if (m.SupportedEfforts.Count == 0)
                {
                    m.SupportedEfforts = new List<string> { "low", "medium", "high" };
                }
                else
                {
                    m.SupportedEfforts = m.SupportedEfforts
                        .OrderBy(e => Array.IndexOf(EffortOrder, e) is int idx and >= 0 ? idx : 99)
                        .ToList();
                }
                if (m.SupportedEfforts.Contains("high")) m.DefaultEffort = "high";
            }

            return grouped.Values.ToList();
        }
        catch (Exception ex)
        {
            _log.Warn("Agy", $"Could not refresh Antigravity models: {ex.Message}");
            return new List<AiModelOption>();
        }
    }

    private List<AiModelOption> LoadCodexModels()
    {
        var result = new List<AiModelOption>();
        var cachePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".codex", "models_cache.json");
        if (!File.Exists(cachePath)) return result;

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(cachePath));
            if (!doc.RootElement.TryGetProperty("models", out var modelsArr) ||
                modelsArr.ValueKind != JsonValueKind.Array)
            {
                return result;
            }

            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var m in modelsArr.EnumerateArray())
            {
                var slug = m.TryGetProperty("slug", out var sEl) ? sEl.GetString() : null;
                if (string.IsNullOrWhiteSpace(slug) || !seen.Add(slug)) continue;

                var display = m.TryGetProperty("display_name", out var dEl) ? dEl.GetString() : slug;
                var defEffort = m.TryGetProperty("default_reasoning_level", out var deEl) ? deEl.GetString() : "medium";
                var efforts = new List<string>();

                if (m.TryGetProperty("supported_reasoning_levels", out var lvlArr) &&
                    lvlArr.ValueKind == JsonValueKind.Array)
                {
                    foreach (var lvl in lvlArr.EnumerateArray())
                    {
                        if (lvl.TryGetProperty("effort", out var eEl))
                        {
                            var eff = eEl.GetString();
                            if (!string.IsNullOrWhiteSpace(eff) && !efforts.Contains(eff))
                            {
                                efforts.Add(eff);
                            }
                        }
                    }
                }

                if (efforts.Count == 0) efforts.AddRange(new[] { "low", "medium", "high", "xhigh" });

                result.Add(new AiModelOption
                {
                    Id = slug,
                    BaseModel = slug,
                    DisplayName = string.IsNullOrWhiteSpace(display) ? slug : display,
                    Engine = "codex",
                    DefaultEffort = string.IsNullOrWhiteSpace(defEffort) ? "medium" : defEffort,
                    SupportedEfforts = efforts
                });
            }
        }
        catch (Exception ex)
        {
            _log.Warn("Codex", $"Could not parse ~/.codex/models_cache.json: {ex.Message}");
        }

        return result;
    }

    public async Task<TurnEnqueueResult> StartTurnAsync(
        string? sessionId,
        string? engine,
        string workspacePath,
        string prompt,
        string? model,
        string? effort,
        string? mode,
        bool? skipPermissions,
        List<string>? attachedFiles)
    {
        var effectiveEngine = string.Equals(engine, "codex", StringComparison.OrdinalIgnoreCase)
            ? "codex"
            : "antigravity";

        var effectiveModel = string.IsNullOrWhiteSpace(model)
            ? (effectiveEngine == "codex" ? "gpt-6.1-sol" : "gemini-4-hydrogen")
            : model.Trim();
        var effectiveEffort = string.IsNullOrWhiteSpace(effort) ? "high" : effort.Trim().ToLowerInvariant();
        var effectiveMode = string.IsNullOrWhiteSpace(mode) ? "auto" : mode.Trim();
        var effectiveWorkspace = string.IsNullOrWhiteSpace(workspacePath) || !Directory.Exists(workspacePath)
            ? _config.Current.DefaultWorkspace
            : Path.GetFullPath(workspacePath);
        var autoApprove = skipPermissions ?? _config.Current.DefaultSkipPermissions;

        var session = _sessions.CreateOrGet(sessionId, effectiveWorkspace, effectiveModel, effectiveMode);
        var gate = _sessionGates.GetOrAdd(session.Id, _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync();
        try
        {
            var isBusy = _activeTurnIds.ContainsKey(session.Id);

            if (!isBusy)
            {
                session.Engine = effectiveEngine;
                session.Model = effectiveModel;
                session.Effort = effectiveEffort;
                session.Mode = effectiveMode;
            }

            if (session.Turns.Count == 0 && !string.IsNullOrWhiteSpace(prompt))
            {
                session.Title = prompt.Length > 48 ? prompt[..48].Trim() + "..." : prompt.Trim();
            }

            var turn = new SessionTurn
            {
                Engine = effectiveEngine,
                Model = effectiveModel,
                Effort = effectiveEffort,
                Prompt = prompt,
                AttachedFiles = attachedFiles ?? new List<string>(),
                Status = isBusy ? "queued" : "running",
                StartedAt = DateTimeOffset.UtcNow
            };

            session.Turns.Add(turn);
            session.IsRunning = true;
            _sessions.Save(session);
            _config.AddPinnedWorkspace(effectiveWorkspace);

            if (isBusy)
            {
                var queue = _sessionQueues.GetOrAdd(session.Id, _ => new ConcurrentQueue<QueuedTurnItem>());
                queue.Enqueue(new QueuedTurnItem(turn, effectiveEngine, effectiveModel, effectiveEffort, effectiveMode, autoApprove));
                _log.Info("Agent", $"Queued turn {turn.Id} for busy session {session.Id} (queue={queue.Count})");

                await EmitAsync("agent.turn_queued", new
                {
                    sessionId = session.Id,
                    turnId = turn.Id,
                    engine = effectiveEngine,
                    workspacePath = session.WorkspacePath,
                    model = effectiveModel,
                    effort = effectiveEffort,
                    mode = effectiveMode,
                    prompt,
                    attachedFiles = turn.AttachedFiles,
                    queueCount = queue.Count
                });

                return new TurnEnqueueResult(session.Id, turn.Id, Queued: true);
            }

            _activeTurnIds[session.Id] = turn.Id;

            await EmitAsync("agent.turn_started", new
            {
                sessionId = session.Id,
                turnId = turn.Id,
                engine = effectiveEngine,
                workspacePath = session.WorkspacePath,
                model = effectiveModel,
                effort = effectiveEffort,
                mode = effectiveMode,
                prompt,
                attachedFiles = turn.AttachedFiles
            });

            LaunchTurnProcess(session, turn, effectiveEngine, effectiveModel, effectiveEffort, effectiveMode, autoApprove);
            return new TurnEnqueueResult(session.Id, turn.Id, Queued: false);
        }
        finally
        {
            gate.Release();
        }
    }

    private void LaunchTurnProcess(
        SessionRecord session,
        SessionTurn turn,
        string engine,
        string model,
        string effort,
        string mode,
        bool autoApprove)
    {
        if (engine == "codex")
        {
            _ = Task.Run(() => RunCodexProcessAsync(session, turn, model, effort, autoApprove));
        }
        else
        {
            _ = Task.Run(() => RunAgyProcessAsync(session, turn, model, effort, mode, autoApprove));
        }
    }

    public bool CancelSession(string sessionId, bool clearQueue = false)
    {
        var anyCancelled = false;
        var session = _sessions.Get(sessionId);

        if (clearQueue && _sessionQueues.TryGetValue(sessionId, out var queue))
        {
            while (queue.TryDequeue(out var queued))
            {
                if (queued.Turn.Status == "queued")
                {
                    queued.Turn.Status = "cancelled";
                    anyCancelled = true;
                    _ = EmitAsync("agent.turn_finished", new
                    {
                        sessionId,
                        turnId = queued.Turn.Id,
                        status = "cancelled",
                        response = string.Empty,
                        needsDecision = false,
                        hasQueuedNext = false
                    });
                }
            }
        }

        if (session != null && _activeTurnIds.TryGetValue(sessionId, out var activeTurnId))
        {
            var activeTurn = session.Turns.FirstOrDefault(t => t.Id == activeTurnId);
            if (activeTurn != null && activeTurn.Status == "running")
            {
                activeTurn.Status = "cancelled";
            }
            _sessions.Save(session);
        }

        if (_activeProcesses.TryRemove(sessionId, out var proc))
        {
            try
            {
                if (!proc.HasExited) proc.Kill(entireProcessTree: true);
                ActiveRunsChanged?.Invoke();
                _log.Info("Agent", $"Cancelled active run for session {sessionId}");
                return true;
            }
            catch (Exception ex)
            {
                _log.Warn("Agent", $"Failed to cancel session {sessionId}: {ex.Message}");
            }
        }

        if (anyCancelled && session != null)
        {
            session.IsRunning = _activeTurnIds.ContainsKey(sessionId);
            _sessions.Save(session);
        }
        return anyCancelled;
    }

    public bool CancelTurn(string sessionId, string turnId)
    {
        if (_activeTurnIds.TryGetValue(sessionId, out var activeTurnId) && activeTurnId == turnId)
        {
            return CancelSession(sessionId, clearQueue: false);
        }

        var session = _sessions.Get(sessionId);
        var turn = session?.Turns.FirstOrDefault(t => t.Id == turnId);
        if (session == null || turn == null || turn.Status != "queued") return false;

        turn.Status = "cancelled";
        _sessions.Save(session);
        _ = EmitAsync("agent.turn_finished", new
        {
            sessionId,
            turnId,
            status = "cancelled",
            response = string.Empty,
            needsDecision = false,
            hasQueuedNext = _activeTurnIds.ContainsKey(sessionId)
        });
        _log.Info("Agent", $"Cancelled queued turn {turnId} in session {sessionId}");
        return true;
    }

    private async Task RunAgyProcessAsync(
        SessionRecord session,
        SessionTurn turn,
        string baseModel,
        string effort,
        string mode,
        bool skipPermissions)
    {
        if (!IsAgyInstalled)
        {
            await FinishTurnWithErrorAsync(session, turn,
                $"Antigravity CLI (`agy.exe`) was not found at `{_config.Current.AgyExecutablePath}`.",
                skipPermissions);
            return;
        }

        var resolvedModelId = ResolveAgyModelId(baseModel, effort);
        var prompt = BuildPromptWithFiles(turn);

        var psi = new ProcessStartInfo
        {
            FileName = _config.Current.AgyExecutablePath,
            WorkingDirectory = session.WorkspacePath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        psi.ArgumentList.Add("-p");
        psi.ArgumentList.Add(prompt);
        psi.ArgumentList.Add("--output-format");
        psi.ArgumentList.Add("stream-json");
        psi.ArgumentList.Add("--model");
        psi.ArgumentList.Add(resolvedModelId);
        psi.ArgumentList.Add("--effort");
        psi.ArgumentList.Add(effort is "ultra" ? "max" : effort);

        if (mode is "auto" or "accept-edits" or "plan")
        {
            psi.ArgumentList.Add("--mode");
            psi.ArgumentList.Add(mode);
        }

        if (skipPermissions)
        {
            psi.ArgumentList.Add("--dangerously-skip-permissions");
        }

        if (!string.IsNullOrWhiteSpace(session.AgyConversationId))
        {
            psi.ArgumentList.Add("--conversation");
            psi.ArgumentList.Add(session.AgyConversationId);
        }

        Process? proc = null;
        try
        {
            proc = new Process { StartInfo = psi };
            proc.Start();
            _activeProcesses[session.Id] = proc;
            ActiveRunsChanged?.Invoke();

            _log.Info("Agy", $"Started {resolvedModelId} (effort={effort}) in {session.WorkspacePath}");

            var stderrTask = proc.StandardError.ReadToEndAsync();
            while (true)
            {
                var line = await proc.StandardOutput.ReadLineAsync();
                if (line == null) break;
                if (string.IsNullOrWhiteSpace(line)) continue;
                await ProcessAgyNdjsonLineAsync(session, turn, line);
            }

            await proc.WaitForExitAsync();
            var stderr = await stderrTask;

            if (turn.Status == "running")
            {
                turn.Status = proc.ExitCode == 0 ? "success" : "error";
                if (proc.ExitCode != 0 && string.IsNullOrWhiteSpace(turn.ResponseText))
                {
                    turn.ResponseText = string.IsNullOrWhiteSpace(stderr)
                        ? $"agy.exe exited with code {proc.ExitCode}."
                        : stderr.Trim();
                }
            }
        }
        catch (Exception ex)
        {
            if (turn.Status == "running")
            {
                turn.Status = "error";
                if (string.IsNullOrWhiteSpace(turn.ResponseText))
                {
                    turn.ResponseText = $"Antigravity error: {ex.Message}";
                }
            }
            _log.Error("Agy", $"Session {session.Id} error: {ex.Message}");
        }
        finally
        {
            await CompleteTurnCleanupAsync(session, turn, proc, skipPermissions);
        }
    }

    private async Task RunCodexProcessAsync(
        SessionRecord session,
        SessionTurn turn,
        string model,
        string effort,
        bool skipPermissions)
    {
        if (!IsCodexInstalled)
        {
            await FinishTurnWithErrorAsync(session, turn,
                $"Codex CLI (`codex.exe`) was not found. Configure its path in WEP Host settings.",
                skipPermissions);
            return;
        }

        var prompt = BuildPromptWithFiles(turn);
        var psi = new ProcessStartInfo
        {
            FileName = _config.Current.CodexExecutablePath,
            WorkingDirectory = session.WorkspacePath,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        var isResume = !string.IsNullOrWhiteSpace(session.CodexThreadId);
        psi.ArgumentList.Add("exec");
        if (isResume) psi.ArgumentList.Add("resume");
        psi.ArgumentList.Add("--json");
        psi.ArgumentList.Add("--skip-git-repo-check");
        psi.ArgumentList.Add("-m");
        psi.ArgumentList.Add(model);
        psi.ArgumentList.Add("-c");
        psi.ArgumentList.Add($"model_reasoning_effort=\"{effort}\"");

        if (skipPermissions)
        {
            psi.ArgumentList.Add("--dangerously-bypass-approvals-and-sandbox");
        }
        else if (!isResume)
        {
            psi.ArgumentList.Add("--full-auto");
        }

        if (!isResume)
        {
            psi.ArgumentList.Add("-C");
            psi.ArgumentList.Add(session.WorkspacePath);
        }
        else
        {
            psi.ArgumentList.Add(session.CodexThreadId!);
        }

        psi.ArgumentList.Add("-"); // Read prompt cleanly from stdin

        var sw = Stopwatch.StartNew();
        Process? proc = null;
        try
        {
            proc = new Process { StartInfo = psi };
            proc.Start();
            _activeProcesses[session.Id] = proc;
            ActiveRunsChanged?.Invoke();

            _log.Info("Codex", $"Started {model} (effort={effort}, resume={isResume}) in {session.WorkspacePath}");

            await proc.StandardInput.WriteAsync(prompt);
            await proc.StandardInput.FlushAsync();
            proc.StandardInput.Close();

            var stderrTask = proc.StandardError.ReadToEndAsync();
            while (true)
            {
                var line = await proc.StandardOutput.ReadLineAsync();
                if (line == null) break;
                if (string.IsNullOrWhiteSpace(line)) continue;
                await ProcessCodexJsonLineAsync(session, turn, line, sw);
            }

            await proc.WaitForExitAsync();
            var stderr = await stderrTask;
            turn.DurationSeconds = sw.Elapsed.TotalSeconds;

            if (turn.Status == "running")
            {
                turn.Status = proc.ExitCode == 0 ? "success" : "error";
                if (proc.ExitCode != 0 && string.IsNullOrWhiteSpace(turn.ResponseText))
                {
                    turn.ResponseText = string.IsNullOrWhiteSpace(stderr)
                        ? $"codex.exe exited with code {proc.ExitCode}."
                        : stderr.Trim();
                }
            }
        }
        catch (Exception ex)
        {
            if (turn.Status == "running")
            {
                turn.Status = "error";
                if (string.IsNullOrWhiteSpace(turn.ResponseText))
                {
                    turn.ResponseText = $"Codex error: {ex.Message}";
                }
            }
            _log.Error("Codex", $"Session {session.Id} error: {ex.Message}");
        }
        finally
        {
            await CompleteTurnCleanupAsync(session, turn, proc, skipPermissions);
        }
    }

    private async Task ProcessCodexJsonLineAsync(SessionRecord session, SessionTurn turn, string jsonLine, Stopwatch sw)
    {
        try
        {
            using var doc = JsonDocument.Parse(jsonLine);
            var root = doc.RootElement;
            if (!root.TryGetProperty("type", out var typeProp)) return;
            var eventType = typeProp.GetString();

            if (eventType == "thread.started" && root.TryGetProperty("thread_id", out var tidProp))
            {
                var tid = tidProp.GetString();
                if (!string.IsNullOrWhiteSpace(tid))
                {
                    session.CodexThreadId = tid;
                    _sessions.Save(session);
                }
                return;
            }

            if (eventType is "item.started" or "item.updated" or "item.completed" &&
                root.TryGetProperty("item", out var item))
            {
                var itemType = item.TryGetProperty("type", out var itEl) ? itEl.GetString() : string.Empty;
                var itemId = item.TryGetProperty("id", out var idEl) ? (idEl.GetString() ?? "0") : "0";

                if (itemType == "agent_message" && item.TryGetProperty("text", out var textEl))
                {
                    var full = textEl.GetString() ?? string.Empty;
                    if (full.Length > turn.ResponseText.Length && full.StartsWith(turn.ResponseText, StringComparison.Ordinal))
                    {
                        var delta = full[turn.ResponseText.Length..];
                        turn.ResponseText = full;
                        await EmitAsync("agent.text_delta", new { sessionId = session.Id, turnId = turn.Id, delta });
                    }
                    else if (!string.IsNullOrEmpty(full) && full != turn.ResponseText)
                    {
                        var delta = string.IsNullOrEmpty(turn.ResponseText) ? full : "\n" + full;
                        turn.ResponseText += delta;
                        await EmitAsync("agent.text_delta", new { sessionId = session.Id, turnId = turn.Id, delta });
                    }
                }
                else if (itemType == "reasoning" && item.TryGetProperty("text", out var thinkEl))
                {
                    var fullThink = thinkEl.GetString() ?? string.Empty;
                    if (fullThink.Length > turn.ThinkingText.Length)
                    {
                        var delta = fullThink.StartsWith(turn.ThinkingText, StringComparison.Ordinal)
                            ? fullThink[turn.ThinkingText.Length..]
                            : fullThink;
                        turn.ThinkingText = fullThink;
                        await EmitAsync("agent.thinking_delta", new { sessionId = session.Id, turnId = turn.Id, delta });
                    }
                }
                else if (itemType is "command_execution" or "file_change" or "mcp_tool_call" or "web_search")
                {
                    var stepIdx = int.TryParse(itemId.Replace("item_", ""), out var n) ? n : turn.ToolSteps.Count;
                    var isDone = eventType == "item.completed";
                    var toolName = itemType switch
                    {
                        "command_execution" => "codex_shell",
                        "file_change" => "codex_patch",
                        "mcp_tool_call" => item.TryGetProperty("tool", out var tl) ? (tl.GetString() ?? "mcp_tool") : "mcp_tool",
                        _ => itemType ?? "tool"
                    };

                    var paramsJson = item.TryGetProperty("command", out var cmdEl)
                        ? JsonSerializer.Serialize(new { command = cmdEl.GetString() })
                        : item.GetRawText();

                    var output = item.TryGetProperty("aggregated_output", out var outEl)
                        ? (outEl.GetString() ?? string.Empty)
                        : (item.TryGetProperty("changes", out var chEl) ? chEl.GetRawText() : string.Empty);

                    var existing = turn.ToolSteps.FirstOrDefault(s => s.StepIndex == stepIdx);
                    if (existing == null)
                    {
                        existing = new AgentToolStep
                        {
                            StepIndex = stepIdx,
                            ToolName = toolName,
                            State = isDone ? "DONE" : "ACTIVE",
                            ParametersJson = paramsJson,
                            Output = output
                        };
                        turn.ToolSteps.Add(existing);
                    }
                    else
                    {
                        existing.State = isDone ? "DONE" : "ACTIVE";
                        if (!string.IsNullOrEmpty(output)) existing.Output = output;
                    }

                    if (output.Contains("approval", StringComparison.OrdinalIgnoreCase) &&
                        output.Contains("required", StringComparison.OrdinalIgnoreCase))
                    {
                        await MarkNeedsDecisionAsync(session, turn, $"Tool `{toolName}` requires your approval or decision.");
                    }

                    await EmitAsync("agent.tool_step", new { sessionId = session.Id, turnId = turn.Id, step = existing });
                }

                _sessions.Save(session);
                return;
            }

            if (eventType is "approval_request" or "exec_approval_request" or "apply_patch_approval_request" or "user_input_request")
            {
                var decisionMsg = root.TryGetProperty("message", out var msgEl)
                    ? (msgEl.GetString() ?? "Approval or user decision required to continue.")
                    : "Approval or user decision required to continue.";
                await MarkNeedsDecisionAsync(session, turn, decisionMsg);
                return;
            }

            if (eventType == "turn.completed")
            {
                turn.Status = "success";
                turn.DurationSeconds = sw.Elapsed.TotalSeconds;
                if (root.TryGetProperty("usage", out var uEl))
                {
                    var inp = uEl.TryGetProperty("input_tokens", out var iP) ? iP.GetInt32() : 0;
                    var outp = uEl.TryGetProperty("output_tokens", out var oP) ? oP.GetInt32() : 0;
                    var cached = uEl.TryGetProperty("cached_input_tokens", out var cP) ? cP.GetInt32() : 0;
                    var reasoning = uEl.TryGetProperty("reasoning_output_tokens", out var rP) ? rP.GetInt32() : 0;
                    turn.Usage = new UsageMetrics
                    {
                        InputTokens = inp,
                        OutputTokens = outp,
                        CacheReadTokens = cached,
                        ThinkingTokens = reasoning,
                        TotalTokens = inp + outp
                    };
                }
                _sessions.Save(session);
            }
        }
        catch (Exception ex)
        {
            _log.Warn("Codex", $"JSONL parse warning: {ex.Message}");
        }
    }

    private async Task ProcessAgyNdjsonLineAsync(SessionRecord session, SessionTurn turn, string jsonLine)
    {
        try
        {
            using var doc = JsonDocument.Parse(jsonLine);
            var root = doc.RootElement;
            if (!root.TryGetProperty("event", out var eventProp)) return;
            var eventName = eventProp.GetString();

            if (root.TryGetProperty("conversation_id", out var convProp))
            {
                var cid = convProp.GetString();
                if (!string.IsNullOrWhiteSpace(cid)) session.AgyConversationId = cid;
            }

            if (eventName == "init")
            {
                await EmitAsync("agent.init", new
                {
                    sessionId = session.Id,
                    turnId = turn.Id,
                    agyConversationId = session.AgyConversationId
                });
                return;
            }

            if (eventName is "permission_request" or "approval_request" or "input_required" or "decision_required" or "user_input" or "waiting_for_user")
            {
                var decisionMsg = root.TryGetProperty("message", out var msgEl)
                    ? (msgEl.GetString() ?? "User decision required to continue.")
                    : "User decision required to continue.";
                await MarkNeedsDecisionAsync(session, turn, decisionMsg);
                return;
            }

            if (eventName == "step_update" && root.TryGetProperty("step_update", out var step))
            {
                var stepType = step.TryGetProperty("step_type", out var st) ? st.GetString() : string.Empty;
                var state = step.TryGetProperty("state", out var stateEl) ? stateEl.GetString() : string.Empty;
                var stepIndex = step.TryGetProperty("step_index", out var idxEl) ? idxEl.GetInt32() : 0;

                if (step.TryGetProperty("text_delta", out var tdEl))
                {
                    var delta = tdEl.GetString() ?? string.Empty;
                    if (!string.IsNullOrEmpty(delta))
                    {
                        turn.ResponseText += delta;
                        await EmitAsync("agent.text_delta", new { sessionId = session.Id, turnId = turn.Id, delta });
                    }
                }

                if (step.TryGetProperty("thinking_delta", out var thEl))
                {
                    var tDelta = thEl.GetString() ?? string.Empty;
                    if (!string.IsNullOrEmpty(tDelta))
                    {
                        turn.ThinkingText += tDelta;
                        await EmitAsync("agent.thinking_delta", new { sessionId = session.Id, turnId = turn.Id, delta = tDelta });
                    }
                }

                if (stepType == "tool")
                {
                    var toolName = step.TryGetProperty("tool_name", out var tn) ? (tn.GetString() ?? "tool") : "tool";
                    var paramsJson = string.Empty;
                    var output = string.Empty;
                    double? duration = step.TryGetProperty("duration_seconds", out var durEl) ? durEl.GetDouble() : null;

                    if (step.TryGetProperty("tool_info", out var infoEl))
                    {
                        if (infoEl.TryGetProperty("parameters", out var pEl)) paramsJson = pEl.GetRawText();
                        if (infoEl.TryGetProperty("output", out var oEl)) output = oEl.GetString() ?? oEl.GetRawText();
                    }

                    var existing = turn.ToolSteps.FirstOrDefault(t => t.StepIndex == stepIndex);
                    if (existing == null)
                    {
                        existing = new AgentToolStep
                        {
                            StepIndex = stepIndex,
                            ToolName = toolName,
                            State = state ?? "ACTIVE",
                            ParametersJson = paramsJson,
                            Output = output,
                            DurationSeconds = duration
                        };
                        turn.ToolSteps.Add(existing);
                    }
                    else
                    {
                        existing.State = state ?? existing.State;
                        if (!string.IsNullOrEmpty(paramsJson)) existing.ParametersJson = paramsJson;
                        if (!string.IsNullOrEmpty(output)) existing.Output = output;
                        existing.DurationSeconds = duration ?? existing.DurationSeconds;
                    }

                    if (string.Equals(state, "WAITING", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(state, "NEEDS_APPROVAL", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(state, "BLOCKED", StringComparison.OrdinalIgnoreCase))
                    {
                        await MarkNeedsDecisionAsync(session, turn, $"Tool `{toolName}` is waiting for your approval or decision.");
                    }

                    await EmitAsync("agent.tool_step", new { sessionId = session.Id, turnId = turn.Id, step = existing });
                }
                else if (stepType is "approval" or "question" or "decision" or "user_input")
                {
                    var decisionMsg = step.TryGetProperty("message", out var mEl)
                        ? (mEl.GetString() ?? "User decision required to continue.")
                        : "User decision required to continue.";
                    await MarkNeedsDecisionAsync(session, turn, decisionMsg);
                }

                _sessions.Save(session);
                return;
            }

            if (eventName == "result" && root.TryGetProperty("result", out var res))
            {
                var status = res.TryGetProperty("status", out var sEl) ? sEl.GetString() : "SUCCESS";
                turn.Status = string.Equals(status, "SUCCESS", StringComparison.OrdinalIgnoreCase) ? "success" : "error";
                if (res.TryGetProperty("duration_seconds", out var dEl)) turn.DurationSeconds = dEl.GetDouble();
                if (res.TryGetProperty("response", out var rEl))
                {
                    var finalResp = rEl.GetString();
                    if (!string.IsNullOrWhiteSpace(finalResp) && string.IsNullOrWhiteSpace(turn.ResponseText))
                    {
                        turn.ResponseText = finalResp;
                    }
                }
                if (res.TryGetProperty("usage", out var uEl))
                {
                    turn.Usage = JsonSerializer.Deserialize<UsageMetrics>(uEl.GetRawText());
                }
                _sessions.Save(session);
            }
        }
        catch (Exception ex)
        {
            _log.Warn("Agy", $"NDJSON parse warning: {ex.Message}");
        }
    }

    private async Task FinishTurnWithErrorAsync(SessionRecord session, SessionTurn turn, string errorMessage, bool skipPermissions = true)
    {
        turn.Status = "error";
        turn.ResponseText = errorMessage;
        await CompleteTurnCleanupAsync(session, turn, null, skipPermissions);
    }

    private async Task MarkNeedsDecisionAsync(SessionRecord session, SessionTurn turn, string decisionPrompt)
    {
        if (turn.NeedsDecision && string.Equals(turn.DecisionPrompt, decisionPrompt, StringComparison.Ordinal))
        {
            return;
        }

        turn.NeedsDecision = true;
        turn.DecisionPrompt = decisionPrompt;
        _sessions.Save(session);

        await EmitAsync("agent.decision_required", new
        {
            sessionId = session.Id,
            turnId = turn.Id,
            title = session.Title,
            decisionPrompt,
            status = turn.Status
        });
    }

    private async Task CompleteTurnCleanupAsync(SessionRecord session, SessionTurn turn, Process? proc, bool skipPermissions)
    {
        _activeProcesses.TryRemove(session.Id, out _);
        proc?.Dispose();

        var gate = _sessionGates.GetOrAdd(session.Id, _ => new SemaphoreSlim(1, 1));
        QueuedTurnItem? nextQueued = null;

        await gate.WaitAsync();
        try
        {
            _activeTurnIds.TryRemove(session.Id, out _);

            if (turn.Status != "cancelled" && !turn.NeedsDecision)
            {
                var (needsDecision, decisionPrompt) = EvaluateNeedsDecision(session.Mode, skipPermissions, turn);
                if (needsDecision)
                {
                    turn.NeedsDecision = true;
                    turn.DecisionPrompt = decisionPrompt;
                }
            }

            if (_sessionQueues.TryGetValue(session.Id, out var queue))
            {
                while (queue.TryDequeue(out var candidate))
                {
                    if (candidate.Turn.Status == "queued")
                    {
                        nextQueued = candidate;
                        break;
                    }
                }
            }

            if (nextQueued != null)
            {
                session.IsRunning = true;
                session.Engine = nextQueued.Engine;
                session.Model = nextQueued.Model;
                session.Effort = nextQueued.Effort;
                session.Mode = nextQueued.Mode;
                nextQueued.Turn.Status = "running";
                nextQueued.Turn.StartedAt = DateTimeOffset.UtcNow;
                _activeTurnIds[session.Id] = nextQueued.Turn.Id;
            }
            else
            {
                session.IsRunning = false;
            }

            _sessions.Save(session);
        }
        finally
        {
            gate.Release();
        }

        ActiveRunsChanged?.Invoke();

        if (turn.NeedsDecision)
        {
            await EmitAsync("agent.decision_required", new
            {
                sessionId = session.Id,
                turnId = turn.Id,
                title = session.Title,
                decisionPrompt = turn.DecisionPrompt ?? "User decision required to continue.",
                status = turn.Status
            });
        }

        await EmitAsync("agent.turn_finished", new
        {
            sessionId = session.Id,
            turnId = turn.Id,
            agyConversationId = session.AgyConversationId,
            codexThreadId = session.CodexThreadId,
            status = turn.Status,
            needsDecision = turn.NeedsDecision,
            decisionPrompt = turn.DecisionPrompt,
            hasQueuedNext = nextQueued != null,
            response = turn.ResponseText,
            thinking = turn.ThinkingText,
            durationSeconds = turn.DurationSeconds,
            usage = turn.Usage
        });

        if (nextQueued != null)
        {
            await EmitAsync("agent.turn_started", new
            {
                sessionId = session.Id,
                turnId = nextQueued.Turn.Id,
                engine = nextQueued.Engine,
                workspacePath = session.WorkspacePath,
                model = nextQueued.Model,
                effort = nextQueued.Effort,
                mode = nextQueued.Mode,
                prompt = nextQueued.Turn.Prompt,
                attachedFiles = nextQueued.Turn.AttachedFiles
            });

            LaunchTurnProcess(
                session,
                nextQueued.Turn,
                nextQueued.Engine,
                nextQueued.Model,
                nextQueued.Effort,
                nextQueued.Mode,
                nextQueued.SkipPermissions);
        }
    }

    private static (bool NeedsDecision, string? DecisionPrompt) EvaluateNeedsDecision(string mode, bool skipPermissions, SessionTurn turn)
    {
        var response = turn.ResponseText?.Trim() ?? string.Empty;

        if (string.Equals(mode, "plan", StringComparison.OrdinalIgnoreCase) &&
            turn.Status == "success" &&
            !string.IsNullOrWhiteSpace(response))
        {
            return (true, ExtractDecisionSummary(response, "Plan ready — review and decide how to proceed."));
        }

        if (!skipPermissions && turn.ToolSteps.Any(s =>
                s.Output.Contains("approval", StringComparison.OrdinalIgnoreCase) ||
                s.Output.Contains("permission", StringComparison.OrdinalIgnoreCase)))
        {
            return (true, "Permission or approval is required to continue.");
        }

        if (string.IsNullOrWhiteSpace(response))
        {
            return (false, null);
        }

        var tail = response.Length > 500 ? response[^500..] : response;
        var lowerTail = tail.ToLowerInvariant();
        var decisionKeywords = new[]
        {
            "which option", "would you like me to", "do you want me to", "should i proceed",
            "please confirm", "let me know which", "how would you like to proceed",
            "awaiting your approval", "requires your confirmation", "choose one of",
            "bạn muốn", "bạn có muốn", "vui lòng xác nhận", "chọn phương án",
            "bạn chọn", "tiếp tục không", "quyết định"
        };

        var endsWithQuestion = tail.TrimEnd().EndsWith('?');
        var hasDecisionCue = decisionKeywords.Any(k => lowerTail.Contains(k, StringComparison.Ordinal));

        if (hasDecisionCue || (endsWithQuestion && (lowerTail.Contains("option") || lowerTail.Contains("prefer") || lowerTail.Contains("proceed") || lowerTail.Contains("confirm") || lowerTail.Contains("chọn") || lowerTail.Contains("?"))))
        {
            return (true, ExtractDecisionSummary(tail, "Agent is asking for your decision to continue."));
        }

        return (false, null);
    }

    private static string ExtractDecisionSummary(string text, string fallback)
    {
        var lines = text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (lines.Length == 0) return fallback;
        var summary = string.Join(" ", lines.TakeLast(2));
        if (summary.Length > 180) summary = summary[^180..];
        return string.IsNullOrWhiteSpace(summary) ? fallback : summary;
    }

    private string ResolveAgyModelId(string baseModel, string effort)
    {
        var match = _cachedModels.FirstOrDefault(m =>
            m.Engine == "antigravity" &&
            (m.Id.Equals(baseModel, StringComparison.OrdinalIgnoreCase) ||
             m.RawVariantIds.Contains(baseModel, StringComparer.OrdinalIgnoreCase)));

        if (match != null)
        {
            var candidate = $"{match.BaseModel}-{effort}";
            var exact = match.RawVariantIds.FirstOrDefault(v => v.Equals(candidate, StringComparison.OrdinalIgnoreCase));
            if (exact != null) return exact;
            if (match.RawVariantIds.Count > 0) return match.RawVariantIds[0];
        }

        return baseModel;
    }

    private static string BuildPromptWithFiles(SessionTurn turn)
    {
        if (turn.AttachedFiles.Count == 0) return turn.Prompt;
        var sb = new StringBuilder();
        sb.AppendLine("Context files referenced by user:");
        foreach (var file in turn.AttachedFiles)
        {
            sb.AppendLine($"- {file}");
        }
        sb.AppendLine();
        sb.Append(turn.Prompt);
        return sb.ToString();
    }

    private static (string BaseId, string? Effort) SplitEffortSuffix(string rawId)
    {
        foreach (var eff in EffortOrder)
        {
            var suffix = "-" + eff;
            if (rawId.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
            {
                return (rawId[..^suffix.Length], eff);
            }
        }
        return (rawId, null);
    }

    private static string StripEffortDisplay(string display)
    {
        foreach (var tag in new[] { " (Low)", " (Medium)", " (High)", " (XHigh)", " (Max)", " (Ultra)" })
        {
            if (display.EndsWith(tag, StringComparison.OrdinalIgnoreCase))
            {
                return display[..^tag.Length].Trim();
            }
        }
        return display;
    }

    private Task EmitAsync(string type, object payload)
    {
        return BroadcastEvent?.Invoke(type, payload) ?? Task.CompletedTask;
    }

    private static List<AiModelOption> DefaultAntigravityModels() => new()
    {
        new() { Id = "gemini-4-hydrogen", BaseModel = "gemini-4-hydrogen", DisplayName = "Gemini 4 Hydrogen", Engine = "antigravity", DefaultEffort = "high", SupportedEfforts = new() { "low", "medium", "high", "xhigh" }, RawVariantIds = new() { "gemini-4-hydrogen-low", "gemini-4-hydrogen-medium", "gemini-4-hydrogen-high", "gemini-4-hydrogen-xhigh" } },
        new() { Id = "gemini-4-argon", BaseModel = "gemini-4-argon", DisplayName = "Gemini 4 Argon", Engine = "antigravity", DefaultEffort = "high", SupportedEfforts = new() { "low", "medium", "high" }, RawVariantIds = new() { "gemini-4-argon-low", "gemini-4-argon-medium", "gemini-4-argon-high" } },
        new() { Id = "gemini-3.8-flash", BaseModel = "gemini-3.8-flash", DisplayName = "Gemini 3.8 Flash", Engine = "antigravity", DefaultEffort = "high", SupportedEfforts = new() { "low", "medium", "high" }, RawVariantIds = new() { "gemini-3.8-flash-low", "gemini-3.8-flash-medium", "gemini-3.8-flash-high" } },
        new() { Id = "claude-opus-5-5", BaseModel = "claude-opus-5-5", DisplayName = "Claude Opus 5.5", Engine = "antigravity", DefaultEffort = "high", SupportedEfforts = new() { "low", "medium", "high" }, RawVariantIds = new() { "claude-opus-5-5-low", "claude-opus-5-5-medium", "claude-opus-5-5-high" } },
        new() { Id = "claude-sonnet-5-5", BaseModel = "claude-sonnet-5-5", DisplayName = "Claude Sonnet 5.5", Engine = "antigravity", DefaultEffort = "high", SupportedEfforts = new() { "low", "medium", "high" }, RawVariantIds = new() { "claude-sonnet-5-5-low", "claude-sonnet-5-5-medium", "claude-sonnet-5-5-high" } }
    };

    private static List<AiModelOption> DefaultCodexModels() => new()
    {
        new() { Id = "gpt-6.1-sol", BaseModel = "gpt-6.1-sol", DisplayName = "GPT-6.1 Sol", Engine = "codex", DefaultEffort = "medium", SupportedEfforts = new() { "low", "medium", "high", "xhigh", "max", "ultra" } },
        new() { Id = "gpt-6.1-terra", BaseModel = "gpt-6.1-terra", DisplayName = "GPT-6.1 Terra", Engine = "codex", DefaultEffort = "medium", SupportedEfforts = new() { "low", "medium", "high", "xhigh", "max", "ultra" } },
        new() { Id = "gpt-6-astra", BaseModel = "gpt-6-astra", DisplayName = "GPT-6 Astra", Engine = "codex", DefaultEffort = "medium", SupportedEfforts = new() { "low", "medium", "high", "xhigh", "max", "ultra" } }
    };

    private static List<AiModelOption> DefaultModels()
    {
        var list = new List<AiModelOption>();
        list.AddRange(DefaultAntigravityModels());
        list.AddRange(DefaultCodexModels());
        return list;
    }
}
