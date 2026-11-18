using System.Collections.Concurrent;
using System.IO;
using System.Text.Json;
using WEP.Host.Models;

namespace WEP.Host.Services;

public sealed class SessionStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private readonly ConfigService _config;
    private readonly ConcurrentDictionary<string, SessionRecord> _sessions = new();
    private readonly object _fileLock = new();

    public event Action? SessionsUpdated;

    public SessionStore(ConfigService config)
    {
        _config = config;
        LoadAll();
    }

    public IReadOnlyList<SessionRecord> ListAll()
    {
        return _sessions.Values
            .OrderByDescending(s => s.UpdatedAt)
            .ToList();
    }

    public SessionRecord? Get(string id)
    {
        return _sessions.TryGetValue(id, out var session) ? session : null;
    }

    public SessionRecord CreateOrGet(string? sessionId, string workspacePath, string model, string mode)
    {
        if (!string.IsNullOrWhiteSpace(sessionId) && _sessions.TryGetValue(sessionId, out var existing))
        {
            if (!string.IsNullOrWhiteSpace(workspacePath)) existing.WorkspacePath = workspacePath;
            if (!string.IsNullOrWhiteSpace(model)) existing.Model = model;
            if (!string.IsNullOrWhiteSpace(mode)) existing.Mode = mode;
            existing.UpdatedAt = DateTimeOffset.UtcNow;
            Save(existing);
            return existing;
        }

        var session = new SessionRecord
        {
            Id = string.IsNullOrWhiteSpace(sessionId) ? Guid.NewGuid().ToString("N") : sessionId,
            WorkspacePath = string.IsNullOrWhiteSpace(workspacePath) ? _config.Current.DefaultWorkspace : workspacePath,
            Model = string.IsNullOrWhiteSpace(model) ? "gemini-4-hydrogen-high" : model,
            Mode = string.IsNullOrWhiteSpace(mode) ? "auto" : mode,
            CreatedAt = DateTimeOffset.UtcNow,
            UpdatedAt = DateTimeOffset.UtcNow
        };
        _sessions[session.Id] = session;
        Save(session);
        SessionsUpdated?.Invoke();
        return session;
    }

    public void Save(SessionRecord session)
    {
        session.UpdatedAt = DateTimeOffset.UtcNow;
        _sessions[session.Id] = session;

        var path = Path.Combine(_config.SessionsFolder, $"{SanitizeFileName(session.Id)}.json");
        lock (_fileLock)
        {
            var json = JsonSerializer.Serialize(session, JsonOptions);
            File.WriteAllText(path, json);
        }
        SessionsUpdated?.Invoke();
    }

    public bool Delete(string sessionId)
    {
        var removed = _sessions.TryRemove(sessionId, out _);
        var path = Path.Combine(_config.SessionsFolder, $"{SanitizeFileName(sessionId)}.json");
        lock (_fileLock)
        {
            if (File.Exists(path)) File.Delete(path);
        }
        if (removed) SessionsUpdated?.Invoke();
        return removed;
    }

    private void LoadAll()
    {
        if (!Directory.Exists(_config.SessionsFolder)) return;

        foreach (var file in Directory.EnumerateFiles(_config.SessionsFolder, "*.json"))
        {
            try
            {
                var json = File.ReadAllText(file);
                var session = JsonSerializer.Deserialize<SessionRecord>(json, JsonOptions);
                if (session != null && !string.IsNullOrWhiteSpace(session.Id))
                {
                    session.IsRunning = false;
                    foreach (var t in session.Turns)
                    {
                        if (t.Status == "running") t.Status = "interrupted";
                    }
                    _sessions[session.Id] = session;
                }
            }
            catch
            {
                // Skip corrupted session file.
            }
        }
    }

    private static string SanitizeFileName(string id)
    {
        foreach (var c in Path.GetInvalidFileNameChars())
        {
            id = id.Replace(c, '_');
        }
        return id;
    }
}
