using System.Text.Json.Serialization;

namespace WEP.Host.Models;

public sealed class HostConfig
{
    public int Port { get; set; } = 8420;
    public string AuthToken { get; set; } = string.Empty;
    public string DeviceName { get; set; } = Environment.MachineName;
    public string DefaultWorkspace { get; set; } = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public bool AutoStartWithWindows { get; set; } = false;
    public bool MinimizeToTrayOnClose { get; set; } = true;
    public bool KeepAwake { get; set; } = true;
    public bool StartTunnelOnLaunch { get; set; } = true;
    public string TunnelMode { get; set; } = "quick"; // "quick" | "named" | "off"
    public string CloudflareTunnelToken { get; set; } = string.Empty;
    public string CustomPublicDomain { get; set; } = string.Empty;
    public string AgyExecutablePath { get; set; } = string.Empty;
    public string CodexExecutablePath { get; set; } = string.Empty;
    public string CursorCliPath { get; set; } = string.Empty;
    public bool DefaultSkipPermissions { get; set; } = true;
    public List<string> PinnedWorkspaces { get; set; } = new();
    public List<string> AllowedRoots { get; set; } = new();
}

public sealed class AiModelOption
{
    public string Id { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string Engine { get; set; } = "antigravity"; // "antigravity" | "codex"
    public string BaseModel { get; set; } = string.Empty;
    public string DefaultEffort { get; set; } = "high";
    public List<string> SupportedEfforts { get; set; } = new() { "low", "medium", "high" };
    public List<string> RawVariantIds { get; set; } = new();
}

public sealed class SessionRecord
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Engine { get; set; } = "antigravity"; // "antigravity" | "codex"
    public string? AgyConversationId { get; set; }
    public string? CodexThreadId { get; set; }
    public string Title { get; set; } = "New Conversation";
    public string WorkspacePath { get; set; } = string.Empty;
    public string Model { get; set; } = "gemini-4-hydrogen";
    public string Effort { get; set; } = "high";
    public string Mode { get; set; } = "auto";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
    public bool IsRunning { get; set; }
    public List<SessionTurn> Turns { get; set; } = new();
}

public sealed class SessionTurn
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Engine { get; set; } = "antigravity";
    public string Model { get; set; } = string.Empty;
    public string Effort { get; set; } = string.Empty;
    public string Prompt { get; set; } = string.Empty;
    public List<string> AttachedFiles { get; set; } = new();
    public string ResponseText { get; set; } = string.Empty;
    public string ThinkingText { get; set; } = string.Empty;
    public string Status { get; set; } = "running"; // running | success | error | cancelled
    public double DurationSeconds { get; set; }
    public UsageMetrics? Usage { get; set; }
    public DateTimeOffset StartedAt { get; set; } = DateTimeOffset.UtcNow;
    public List<AgentToolStep> ToolSteps { get; set; } = new();
}

public sealed class AgentToolStep
{
    public int StepIndex { get; set; }
    public string ToolName { get; set; } = string.Empty;
    public string State { get; set; } = "ACTIVE"; // ACTIVE | DONE
    public string ParametersJson { get; set; } = string.Empty;
    public string Output { get; set; } = string.Empty;
    public double? DurationSeconds { get; set; }
}

public sealed class UsageMetrics
{
    [JsonPropertyName("input_tokens")]
    public int InputTokens { get; set; }
    [JsonPropertyName("output_tokens")]
    public int OutputTokens { get; set; }
    [JsonPropertyName("thinking_tokens")]
    public int ThinkingTokens { get; set; }
    [JsonPropertyName("cache_read_tokens")]
    public int CacheReadTokens { get; set; }
    [JsonPropertyName("total_tokens")]
    public int TotalTokens { get; set; }
}

public sealed class CursorLiveState
{
    public bool IsCursorRunning { get; set; }
    public int ProcessCount { get; set; }
    public string? ActiveWorkspace { get; set; }
    public List<string> ActiveWindowTitles { get; set; } = new();
    public List<string> OpenWorkspaces { get; set; } = new();
}

public sealed class ExtensionItem
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Publisher { get; set; } = string.Empty;
    public string Version { get; set; } = string.Empty;
    public string Source { get; set; } = "cursor"; // "cursor" | "antigravity" | "codex" | "mcp"
    public bool Enabled { get; set; } = true;
    public string Description { get; set; } = string.Empty;
    public string InstallPath { get; set; } = string.Empty;
}

public sealed class CodexThreadSummary
{
    public string Id { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string UpdatedAt { get; set; } = string.Empty;
}

public sealed class ExtensionActionRequest
{
    public string Id { get; set; } = string.Empty;
    public string Source { get; set; } = "cursor";
    public bool? Enable { get; set; }
}

public sealed class CursorOpenRequest
{
    public string Path { get; set; } = string.Empty;
    public int? Line { get; set; }
}

public sealed class CodexImportRequest
{
    public string ThreadId { get; set; } = string.Empty;
    public string? Title { get; set; }
    public string? WorkspacePath { get; set; }
    public string? Model { get; set; }
    public string? Effort { get; set; }
}

public sealed class FsDriveItem
{
    public string Name { get; set; } = string.Empty;
    public string Path { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
    public long TotalBytes { get; set; }
    public long FreeBytes { get; set; }
}

public sealed class FsEntryItem
{
    public string Name { get; set; } = string.Empty;
    public string Path { get; set; } = string.Empty;
    public bool IsDirectory { get; set; }
    public long SizeBytes { get; set; }
    public DateTimeOffset ModifiedAt { get; set; }
    public string Extension { get; set; } = string.Empty;
}

public sealed class FsListResponse
{
    public string CurrentPath { get; set; } = string.Empty;
    public string? ParentPath { get; set; }
    public List<FsEntryItem> Entries { get; set; } = new();
}

public sealed class FileContentResponse
{
    public string Path { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Content { get; set; } = string.Empty;
    public long SizeBytes { get; set; }
    public DateTimeOffset ModifiedAt { get; set; }
    public bool IsBinary { get; set; }
}

public sealed class FileWriteRequest
{
    public string Path { get; set; } = string.Empty;
    public string Content { get; set; } = string.Empty;
}

public sealed class FsPathRequest
{
    public string Path { get; set; } = string.Empty;
    public bool IsDirectory { get; set; }
}

public sealed class FsRenameRequest
{
    public string Path { get; set; } = string.Empty;
    public string NewName { get; set; } = string.Empty;
}

public sealed class GitChangedFile
{
    public string Path { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
}

public sealed class GitStatusResponse
{
    public bool IsGitRepo { get; set; }
    public string Branch { get; set; } = string.Empty;
    public List<GitChangedFile> ChangedFiles { get; set; } = new();
}

public sealed class TerminalExecRequest
{
    public string Cwd { get; set; } = string.Empty;
    public string Command { get; set; } = string.Empty;
    public int TimeoutSeconds { get; set; } = 60;
}

public sealed class TerminalExecResponse
{
    public int ExitCode { get; set; }
    public string Stdout { get; set; } = string.Empty;
    public string Stderr { get; set; } = string.Empty;
    public string Cwd { get; set; } = string.Empty;
    public double DurationSeconds { get; set; }
}

public sealed class PairingPayload
{
    public string Name { get; set; } = string.Empty;
    public string? TunnelUrl { get; set; }
    public string? LanUrl { get; set; }
    public string Token { get; set; } = string.Empty;
    public string Version { get; set; } = "2.0.0";
}

public sealed class WsIncomingMessage
{
    public string Type { get; set; } = string.Empty;
    public string? SessionId { get; set; }
    public string? TurnId { get; set; }
    public string? Engine { get; set; }
    public string? WorkspacePath { get; set; }
    public string? Prompt { get; set; }
    public string? Model { get; set; }
    public string? Effort { get; set; }
    public string? Mode { get; set; }
    public bool? SkipPermissions { get; set; }
    public List<string>? AttachedFiles { get; set; }
    public string? Command { get; set; }
    public string? Cwd { get; set; }
}
