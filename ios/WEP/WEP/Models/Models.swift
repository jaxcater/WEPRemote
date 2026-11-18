import Foundation
import SwiftUI

enum AgentEngine: String, CaseIterable, Codable, Identifiable {
    case antigravity = "antigravity"
    case codex = "codex"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .codex: return "Codex"
        }
    }

    var shortBadge: String {
        switch self {
        case .antigravity: return "AGY"
        case .codex: return "CDX"
        }
    }

    var icon: String {
        switch self {
        case .antigravity: return "sparkles"
        case .codex: return "cpu.fill"
        }
    }
}

enum ReasoningEffort: String, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max, ultra

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Med"
        case .high: return "High"
        case .xhigh: return "XHigh"
        case .max: return "Max"
        case .ultra: return "Ultra"
        }
    }

    var color: Color {
        switch self {
        case .low: return Color(hex: 0x9CA3AF)
        case .medium: return Color(hex: 0x38BDF8)
        case .high: return Color(hex: 0x6366F1)
        case .xhigh: return Color(hex: 0xA855F7)
        case .max: return Color(hex: 0xF59E0B)
        case .ultra: return Color(hex: 0xEC4899)
        }
    }
}

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
    let codexInstalled: Bool?
    let tunnelUrl: String?
    let lanUrl: String?
}

struct CursorLiveState: Codable {
    let isCursorRunning: Bool
    let processCount: Int
    let activeWorkspace: String?
    let activeWindowTitles: [String]
    let openWorkspaces: [String]
}

struct HostInfoResponse: Codable {
    let deviceName: String
    let agyInstalled: Bool
    let codexInstalled: Bool?
    let defaultWorkspace: String
    let pinnedWorkspaces: [String]
    let tunnelUrl: String?
    let tunnelStatus: String?
    let lanUrl: String?
    let defaultSkipPermissions: Bool?
    let cursorLive: CursorLiveState?
    let models: [AiModelOption]
}

struct AiModelOption: Codable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let engine: String?
    let baseModel: String?
    let defaultEffort: String?
    let supportedEfforts: [String]?

    var resolvedEngine: AgentEngine {
        AgentEngine(rawValue: engine ?? "antigravity") ?? .antigravity
    }

    var efforts: [String] {
        if let list = supportedEfforts, !list.isEmpty { return list }
        return ["low", "medium", "high"]
    }
}

struct ExtensionItem: Codable, Identifiable {
    let id: String
    let name: String
    let publisher: String
    let version: String
    let source: String
    var enabled: Bool
    let description: String
    let installPath: String?
}

struct CodexThreadSummary: Codable, Identifiable {
    let id: String
    let title: String
    let updatedAt: String
}

struct SessionRecord: Codable, Identifiable {
    let id: String
    var engine: String?
    var agyConversationId: String?
    var codexThreadId: String?
    var title: String
    var workspacePath: String
    var model: String
    var effort: String?
    var mode: String
    var createdAt: String?
    var updatedAt: String?
    var isRunning: Bool
    var turns: [SessionTurn]

    var queuedTurnCount: Int {
        turns.filter { $0.isQueued }.count
    }

    var hasDecisionPending: Bool {
        turns.last?.requiresUserDecision == true
    }
}

struct SessionTurn: Codable, Identifiable {
    let id: String
    var engine: String?
    var model: String?
    var effort: String?
    var prompt: String
    var attachedFiles: [String]
    var responseText: String
    var thinkingText: String
    var status: String
    var needsDecision: Bool?
    var decisionPrompt: String?
    var durationSeconds: Double
    var usage: UsageMetrics?
    var startedAt: String?
    var toolSteps: [AgentToolStep]

    var isRunning: Bool { status == "running" }
    var isQueued: Bool { status == "queued" }
    var isTerminal: Bool { status != "running" && status != "queued" }
    var requiresUserDecision: Bool {
        needsDecision == true || status == "needs_decision"
    }
}

struct AgentStartResponse: Codable {
    let accepted: Bool?
    let sessionId: String?
    let turnId: String?
    let queued: Bool?
}

struct TurnStateSnapshot: Codable, Equatable {
    let status: String
    let needsDecision: Bool
}

struct PendingPromptItem: Codable, Identifiable {
    let id: String
    let sessionId: String?
    let engine: String
    let workspacePath: String
    let prompt: String
    let model: String
    let effort: String
    let mode: String
    let skipPermissions: Bool
    let attachedFiles: [String]
    let createdAt: Date
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

struct GenericActionResponse: Codable {
    let ok: Bool?
    let message: String?
    let output: String?
}
