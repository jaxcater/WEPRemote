using System.Collections.Concurrent;

namespace WEP.Host.Services;

public sealed class LogEntry
{
    public DateTimeOffset Timestamp { get; init; } = DateTimeOffset.Now;
    public string Level { get; init; } = "INFO";
    public string Source { get; init; } = "Host";
    public string Message { get; init; } = string.Empty;

    public string Formatted => $"[{Timestamp:HH:mm:ss}] [{Level}] [{Source}] {Message}";
}

public sealed class LogService
{
    private readonly ConcurrentQueue<LogEntry> _entries = new();
    private const int MaxEntries = 400;

    public event Action<LogEntry>? OnLog;

    public void Info(string source, string message) => Add("INFO", source, message);
    public void Warn(string source, string message) => Add("WARN", source, message);
    public void Error(string source, string message) => Add("ERR", source, message);

    public IReadOnlyList<LogEntry> Snapshot() => _entries.ToArray();

    private void Add(string level, string source, string message)
    {
        var entry = new LogEntry
        {
            Level = level,
            Source = source,
            Message = message
        };
        _entries.Enqueue(entry);
        while (_entries.Count > MaxEntries && _entries.TryDequeue(out _)) { }
        OnLog?.Invoke(entry);
    }
}
