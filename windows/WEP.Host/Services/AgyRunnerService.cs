using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using WEP.Host.Models;

namespace WEP.Host.Services;

public sealed class AgyRunnerService
{
    private readonly ConfigService _config;
    private readonly SessionStore _sessions;
    private readonly LogService _log;
    private readonly ConcurrentDictionary<string, Process> _activeProcesses = new();
    private List<AgyModelInfo> _cachedModels = DefaultModels();

    public event Func<string, object, Task>? BroadcastEvent;
    public event Action? ActiveRunsChanged;

    public int ActiveRunCount => _activeProcesses.Count;

    public AgyRunnerService(ConfigService config, SessionStore sessions, LogService log)
    {
        _config = config;
        _sessions = sessions;
        _log = log;
    }

    public bool IsAgyInstalled => File.Exists(_config.Current.AgyExecutablePath);

    public async Task<List<AgyModelInfo>> GetModelsAsync(bool forceRefresh = false, CancellationToken ct = default)
    {
        if (!forceRefresh && _cachedModels.Count > 0) return _cachedModels;
        if (!IsAgyInstalled) return _cachedModels;

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
            if (proc == null) return _cachedModels;

            var output = await proc.StandardOutput.ReadToEndAsync(ct);
            await proc.WaitForExitAsync(ct);

            var parsed = new List<AgyModelInfo>();
            foreach (var rawLine in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                var line = rawLine.Trim();
                if (line.StartsWith("Fetching", StringComparison.OrdinalIgnoreCase)) continue;
                var parts = line.Split('\t', 2);
                if (parts.Length == 2 && !string.IsNullOrWhiteSpace(parts[0]))
                {
                    parsed.Add(new AgyModelInfo
                    {
                        Id = parts[0].Trim(),
                        DisplayName = parts[1].Trim()
                    });
                }
            }

            if (parsed.Count > 0) _cachedModels = parsed;
        }
        catch (Exception ex)
        {
            _log.Warn("Agy", $"Could not refresh models: {ex.Message}");
        }

        return _cachedModels;
    }

    public async Task StartTurnAsync(
        string? sessionId,
        string workspacePath,
        string prompt,
        string? model,
        string? mode,
        bool? skipPermissions,
        List<string>? attachedFiles)
    {
        var effectiveModel = string.IsNullOrWhiteSpace(model) ? "gemini-4-hydrogen-high" : model.Trim();
        var effectiveMode = string.IsNullOrWhiteSpace(mode) ? "auto" : mode.Trim();
        var effectiveWorkspace = string.IsNullOrWhiteSpace(workspacePath) || !Directory.Exists(workspacePath)
            ? _config.Current.DefaultWorkspace
            : Path.GetFullPath(workspacePath);

        var session = _sessions.CreateOrGet(sessionId, effectiveWorkspace, effectiveModel, effectiveMode);
        if (session.Turns.Count == 0 && !string.IsNullOrWhiteSpace(prompt))
        {
            session.Title = prompt.Length > 48 ? prompt[..48].Trim() + "..." : prompt.Trim();
        }

        var turn = new SessionTurn
        {
            Prompt = prompt,
            AttachedFiles = attachedFiles ?? new List<string>(),
            Status = "running",
            StartedAt = DateTimeOffset.UtcNow
        };

        session.Turns.Add(turn);
        session.IsRunning = true;
        _sessions.Save(session);
        _config.AddPinnedWorkspace(effectiveWorkspace);

        await EmitAsync("agent.turn_started", new
        {
            sessionId = session.Id,
            turnId = turn.Id,
            workspacePath = session.WorkspacePath,
            model = effectiveModel,
            mode = effectiveMode,
            prompt
        });

        if (!IsAgyInstalled)
        {
            turn.Status = "error";
            turn.ResponseText = $"Antigravity CLI (`agy.exe`) was not found at `{_config.Current.AgyExecutablePath}`.";
            session.IsRunning = false;
            _sessions.Save(session);
            await EmitAsync("agent.turn_finished", new
            {
                sessionId = session.Id,
                turnId = turn.Id,
                status = "error",
                response = turn.ResponseText
            });
            return;
        }

        _ = Task.Run(() => RunAgyProcessAsync(session, turn, effectiveModel, effectiveMode,
            skipPermissions ?? _config.Current.DefaultSkipPermissions));
    }

    public bool CancelSession(string sessionId)
    {
        if (_activeProcesses.TryRemove(sessionId, out var proc))
        {
            try
            {
                if (!proc.HasExited) proc.Kill(entireProcessTree: true);
                ActiveRunsChanged?.Invoke();
                _log.Info("Agy", $"Cancelled active run for session {sessionId}");
                return true;
            }
            catch (Exception ex)
            {
                _log.Warn("Agy", $"Failed to cancel session {sessionId}: {ex.Message}");
            }
        }
        return false;
    }

    private async Task RunAgyProcessAsync(
        SessionRecord session,
        SessionTurn turn,
        string model,
        string mode,
        bool skipPermissions)
    {
        var promptBuilder = new StringBuilder();
        if (turn.AttachedFiles.Count > 0)
        {
            promptBuilder.AppendLine("Context files referenced by user:");
            foreach (var file in turn.AttachedFiles)
            {
                promptBuilder.AppendLine($"- {file}");
            }
            promptBuilder.AppendLine();
        }
        promptBuilder.Append(turn.Prompt);

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
        psi.ArgumentList.Add(promptBuilder.ToString());
        psi.ArgumentList.Add("--output-format");
        psi.ArgumentList.Add("stream-json");
        psi.ArgumentList.Add("--model");
        psi.ArgumentList.Add(model);

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

            _log.Info("Agy", $"Started session {session.Id} in {session.WorkspacePath} ({model})");

            var stderrTask = proc.StandardError.ReadToEndAsync();
            while (true)
            {
                var line = await proc.StandardOutput.ReadLineAsync();
                if (line == null) break;
                if (string.IsNullOrWhiteSpace(line)) continue;

                await ProcessNdjsonLineAsync(session, turn, line);
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
            turn.Status = "error";
            if (string.IsNullOrWhiteSpace(turn.ResponseText))
            {
                turn.ResponseText = $"Agent execution error: {ex.Message}";
            }
            _log.Error("Agy", $"Session {session.Id} error: {ex.Message}");
        }
        finally
        {
            _activeProcesses.TryRemove(session.Id, out _);
            ActiveRunsChanged?.Invoke();
            session.IsRunning = false;
            _sessions.Save(session);
            proc?.Dispose();

            await EmitAsync("agent.turn_finished", new
            {
                sessionId = session.Id,
                turnId = turn.Id,
                agyConversationId = session.AgyConversationId,
                status = turn.Status,
                response = turn.ResponseText,
                thinking = turn.ThinkingText,
                durationSeconds = turn.DurationSeconds,
                usage = turn.Usage
            });
        }
    }

    private async Task ProcessNdjsonLineAsync(SessionRecord session, SessionTurn turn, string jsonLine)
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
                        await EmitAsync("agent.text_delta", new
                        {
                            sessionId = session.Id,
                            turnId = turn.Id,
                            delta
                        });
                    }
                }

                if (step.TryGetProperty("thinking_delta", out var thEl))
                {
                    var tDelta = thEl.GetString() ?? string.Empty;
                    if (!string.IsNullOrEmpty(tDelta))
                    {
                        turn.ThinkingText += tDelta;
                        await EmitAsync("agent.thinking_delta", new
                        {
                            sessionId = session.Id,
                            turnId = turn.Id,
                            delta = tDelta
                        });
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

                    await EmitAsync("agent.tool_step", new
                    {
                        sessionId = session.Id,
                        turnId = turn.Id,
                        step = existing
                    });
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

    private Task EmitAsync(string type, object payload)
    {
        return BroadcastEvent?.Invoke(type, payload) ?? Task.CompletedTask;
    }

    private static List<AgyModelInfo> DefaultModels() => new()
    {
        new() { Id = "gemini-4-hydrogen-high", DisplayName = "Gemini 4 Hydrogen (High)" },
        new() { Id = "gemini-4-hydrogen-medium", DisplayName = "Gemini 4 Hydrogen (Medium)" },
        new() { Id = "gemini-4-argon-high", DisplayName = "Gemini 4 Argon (High)" },
        new() { Id = "gemini-3.8-flash-high", DisplayName = "Gemini 3.8 Flash (High)" },
        new() { Id = "claude-opus-5-5-high", DisplayName = "Claude Opus 5.5 (High)" },
        new() { Id = "claude-sonnet-5-5-high", DisplayName = "Claude Sonnet 5.5 (High)" }
    };
}
