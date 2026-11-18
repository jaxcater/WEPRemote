import Foundation

struct HostProfile: Codable, Identifiable, Equatable {
    var id: String { "\(name)-\(token.prefix(8))" }
    var name: String
    var tunnelUrl: String?
    var lanUrl: String?
    var token: String
    var version: String?
}

struct HealthResponse: Codable {
    let ok: Bool
    let authenticated: Bool?
    let name: String?
    let version: String?
    let agyInstalled: Bool?
    let tunnelUrl: String?
    let lanUrl: String?
}

struct HostInfoResponse: Codable {
    let deviceName: String
    let agyInstalled: Bool
    let defaultWorkspace: String
    let pinnedWorkspaces: [String]
    let tunnelUrl: String?
    let tunnelStatus: String?
    let lanUrl: String?
    let defaultSkipPermissions: Bool?
    let models: [AgyModelInfo]
}

struct AgyModelInfo: Codable, Identifiable, Hashable {
    let id: String
    let displayName: String
}

struct SessionRecord: Codable, Identifiable {
    let id: String
    var agyConversationId: String?
    var title: String
    var workspacePath: String
    var model: String
    var mode: String
    var createdAt: String?
    var updatedAt: String?
    var isRunning: Bool
    var turns: [SessionTurn]
}

struct SessionTurn: Codable, Identifiable {
    let id: String
    var prompt: String
    var attachedFiles: [String]
    var responseText: String
    var thinkingText: String
    var status: String
    var durationSeconds: Double
    var usage: UsageMetrics?
    var startedAt: String?
    var toolSteps: [AgentToolStep]
}

struct AgentToolStep: Codable, Identifiable {
    var id: Int { stepIndex }
    let stepIndex: Int
    let toolName: String
    var state: String
    var parametersJson: String
    var output: String
    var durationSeconds: Double?
}

struct UsageMetrics: Codable {
    let input_tokens: Int?
    let output_tokens: Int?
    let thinking_tokens: Int?
    let cache_read_tokens: Int?
    let total_tokens: Int?
}

struct FsDriveItem: Codable, Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let label: String
    let totalBytes: Int64
    let freeBytes: Int64
}

struct FsEntryItem: Codable, Identifiable, Hashable {
    var id: String { path }
    let Name: String?
    let name: String?
    let path: String
    let isDirectory: Bool
    let sizeBytes: Int64?
    let extensionName: String?

    var displayName: String {
        name ?? Name ?? (path as NSString).lastPathComponent
    }

    enum CodingKeys: String, CodingKey {
        case Name
        case name
        case path
        case isDirectory
        case sizeBytes
        case extensionName = "extension"
    }
}

struct FsListResponse: Codable {
    let currentPath: String
    let parentPath: String?
    let entries: [FsEntryItem]
}

struct FileContentResponse: Codable {
    let path: String
    let name: String
    let content: String
    let sizeBytes: Int64
    let isBinary: Bool
}

struct GitStatusResponse: Codable {
    let isGitRepo: Bool
    let branch: String?
    let changedFiles: [GitChangedFile]
}

struct GitChangedFile: Codable, Identifiable {
    var id: String { path }
    let path: String
    let status: String
}

struct GitDiffResponse: Codable {
    let diff: String
}

struct TerminalExecResponse: Codable {
    let exitCode: Int
    let stdout: String
    let stderr: String
    let cwd: String
    let durationSeconds: Double
}

struct TerminalLogEntry: Identifiable {
    let id = UUID()
    let command: String
    let cwd: String
    let output: String
    let stderr: String
    let exitCode: Int
    let duration: Double
}

enum ExecutionMode: String, CaseIterable, Identifiable {
    case auto = "auto"
    case acceptEdits = "accept-edits"
    case plan = "plan"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .acceptEdits: return "Accept Edits"
        case .plan: return "Plan"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "bolt.fill"
        case .acceptEdits: return "pencil.and.outline"
        case .plan: return "list.bullet.rectangle"
        }
    }
}

struct SlashCommandItem: Identifiable {
    let id: String
    let command: String
    let description: String
    let template: String

    static let builtIn: [SlashCommandItem] = [
        SlashCommandItem(id: "plan", command: "/plan", description: "Create a step-by-step plan before editing", template: "/plan "),
        SlashCommandItem(id: "fix", command: "/fix", description: "Diagnose and fix errors or failing tests", template: "Diagnose and fix the issue in "),
        SlashCommandItem(id: "review", command: "/review", description: "Review recent changes for bugs & edge cases", template: "Review the current codebase and recent changes for bugs, security issues, and improvements."),
        SlashCommandItem(id: "test", command: "/test", description: "Run tests and fix any failures", template: "Run the test suite and verify everything passes."),
        SlashCommandItem(id: "explain", command: "/explain", description: "Explain how this module or folder works", template: "Explain the architecture and key files in this workspace.")
    ]
}
