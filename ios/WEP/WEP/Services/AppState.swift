import Foundation
import SwiftUI

enum MainSurfaceTab: String, CaseIterable {
    case chat
    case explorer
    case code
    case terminal
}

@MainActor
final class AppState: ObservableObject {
    private let profilesKey = "wep.host.profiles.v1"
    private let activeProfileIdKey = "wep.host.activeProfileId.v1"

    let client = WEPClient()

    @Published var profiles: [HostProfile] = []
    @Published var activeProfile: HostProfile?

    @Published var isConnected = false
    @Published var connectionRoute = "Disconnected"
    @Published var connectionError: String?
    @Published var isConnecting = false

    @Published var hostInfo: HostInfoResponse?
    @Published var models: [AgyModelInfo] = [
        AgyModelInfo(id: "gemini-4-hydrogen-high", displayName: "Gemini 4 Hydrogen (High)"),
        AgyModelInfo(id: "gemini-4-argon-high", displayName: "Gemini 4 Argon (High)"),
        AgyModelInfo(id: "gemini-3.8-flash-high", displayName: "Gemini 3.8 Flash (High)"),
        AgyModelInfo(id: "claude-opus-5-5-high", displayName: "Claude Opus 5.5 (High)"),
        AgyModelInfo(id: "claude-sonnet-5-5-high", displayName: "Claude Sonnet 5.5 (High)")
    ]

    @Published var activeWorkspace: String = ""
    @Published var pinnedWorkspaces: [String] = []
    @Published var selectedModel: String = "gemini-4-hydrogen-high"
    @Published var selectedMode: ExecutionMode = .auto
    @Published var skipPermissions: Bool = true

    @Published var sessions: [SessionRecord] = []
    @Published var activeSessionId: String?

    @Published var activeTab: MainSurfaceTab = .chat
    @Published var showSidebar = false
    @Published var showAuxiliaryPane = false
    @Published var showPairingSheet = false
    @Published var showSettingsSheet = false

    // Direct Code Editor state
    @Published var openFilePath: String = ""
    @Published var openFileName: String = ""
    @Published var editorContent: String = ""
    @Published var originalEditorContent: String = ""
    @Published var isLoadingFile = false
    @Published var isSavingFile = false
    @Published var editorMessage: String?

    // Git & Terminal state
    @Published var gitStatus: GitStatusResponse?
    @Published var terminalLogs: [TerminalLogEntry] = []
    @Published var isRunningCommand = false

    var isEditorDirty: Bool {
        !openFilePath.isEmpty && editorContent != originalEditorContent
    }

    var activeSession: SessionRecord? {
        guard let id = activeSessionId else { return nil }
        return sessions.first(where: { $0.id == id })
    }

    var currentTurnIsRunning: Bool {
        activeSession?.isRunning == true
    }

    init() {
        loadProfiles()
        wireWebSocketEvents()

        if let profile = activeProfile {
            Task { await connect(to: profile) }
        } else {
            showPairingSheet = true
        }
    }

    private func wireWebSocketEvents() {
        client.onConnectionStateChange = { [weak self] connected, route in
            Task { @MainActor in
                self?.isConnected = connected
                self?.connectionRoute = route
            }
        }

        client.onWebSocketEvent = { [weak self] type, payload in
            Task { @MainActor in
                self?.handleWsEvent(type: type, payload: payload)
            }
        }
    }

    func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([HostProfile].self, from: data) {
            profiles = decoded
        }

        let activeId = UserDefaults.standard.string(forKey: activeProfileIdKey)
        activeProfile = profiles.first(where: { $0.id == activeId }) ?? profiles.first
    }

    func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        UserDefaults.standard.set(activeProfile?.id, forKey: activeProfileIdKey)
    }

    func addOrUpdateAndConnect(profile: HostProfile) async {
        if let idx = profiles.firstIndex(where: { $0.token == profile.token || $0.name == profile.name }) {
            profiles[idx] = profile
        } else {
            profiles.insert(profile, at: 0)
        }
        activeProfile = profile
        saveProfiles()
        await connect(to: profile)
    }

    func removeProfile(_ profile: HostProfile) {
        profiles.removeAll(where: { $0.id == profile.id })
        if activeProfile?.id == profile.id {
            activeProfile = profiles.first
            client.disconnectWebSocket()
        }
        saveProfiles()
    }

    func connect(to profile: HostProfile) async {
        activeProfile = profile
        saveProfiles()
        isConnecting = true
        connectionError = nil

        do {
            try await client.resolveAndConnect(profile: profile)
            await refreshHostData()
        } catch {
            connectionError = error.localizedDescription
            isConnected = false
        }
        isConnecting = false
    }

    func refreshHostData() async {
        guard let token = activeProfile?.token else { return }
        do {
            let info = try await client.getInfo(token: token)
            self.hostInfo = info
            if !info.models.isEmpty { self.models = info.models }
            self.pinnedWorkspaces = info.pinnedWorkspaces
            if self.activeWorkspace.isEmpty {
                self.activeWorkspace = info.defaultWorkspace
            }
            if let skip = info.defaultSkipPermissions {
                self.skipPermissions = skip
            }

            // Update stored tunnel/lan URLs if host reported fresh ones
            if var current = activeProfile {
                var updated = false
                if let t = info.tunnelUrl, !t.isEmpty, t != current.tunnelUrl {
                    current.tunnelUrl = t
                    updated = true
                }
                if let l = info.lanUrl, !l.isEmpty, l != current.lanUrl {
                    current.lanUrl = l
                    updated = true
                }
                if updated {
                    if let idx = profiles.firstIndex(where: { $0.id == current.id }) {
                        profiles[idx] = current
                    }
                    activeProfile = current
                    saveProfiles()
                }
            }

            let loadedSessions = try await client.listSessions(token: token)
            self.sessions = loadedSessions
            if self.activeSessionId == nil, let first = loadedSessions.first {
                self.activeSessionId = first.id
                if !first.workspacePath.isEmpty {
                    self.activeWorkspace = first.workspacePath
                }
            }

            await refreshGitStatus()
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func refreshGitStatus() async {
        guard let token = activeProfile?.token, !activeWorkspace.isEmpty else { return }
        if let status = try? await client.gitStatus(cwd: activeWorkspace, token: token) {
            self.gitStatus = status
        }
    }

    func startNewConversation() {
        activeSessionId = nil
        activeTab = .chat
        showSidebar = false
    }

    func selectSession(_ session: SessionRecord) {
        activeSessionId = session.id
        if !session.workspacePath.isEmpty {
            activeWorkspace = session.workspacePath
        }
        if !session.model.isEmpty {
            selectedModel = session.model
        }
        if let mode = ExecutionMode(rawValue: session.mode) {
            selectedMode = mode
        }
        activeTab = .chat
        showSidebar = false
        Task { await refreshGitStatus() }
    }

    func openFolderAsWorkspace(_ path: String) async {
        activeWorkspace = path
        if !pinnedWorkspaces.contains(path) {
            pinnedWorkspaces.insert(path, at: 0)
        }
        if let token = activeProfile?.token {
            try? await client.pinWorkspace(path: path, token: token)
        }
        await refreshGitStatus()
    }

    func sendPrompt(_ prompt: String, attachedFiles: [String] = []) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let token = activeProfile?.token else { return }

        let workspace = activeWorkspace.isEmpty ? (hostInfo?.defaultWorkspace ?? "") : activeWorkspace

        do {
            // Ensure we have a session ID locally before streaming starts
            if activeSessionId == nil {
                let created = try await client.createSession(
                    workspacePath: workspace,
                    model: selectedModel,
                    mode: selectedMode.rawValue,
                    token: token
                )
                sessions.insert(created, at: 0)
                activeSessionId = created.id
            }

            try await client.startAgent(
                sessionId: activeSessionId,
                workspacePath: workspace,
                prompt: trimmed,
                model: selectedModel,
                mode: selectedMode.rawValue,
                skipPermissions: skipPermissions,
                attachedFiles: attachedFiles,
                token: token
            )
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func cancelActiveTurn() async {
        guard let sid = activeSessionId, let token = activeProfile?.token else { return }
        try? await client.cancelAgent(sessionId: sid, token: token)
    }

    func openFileInEditor(path: String) async {
        guard let token = activeProfile?.token else { return }
        isLoadingFile = true
        editorMessage = nil
        do {
            let file = try await client.readFile(path: path, token: token)
            if file.isBinary {
                editorMessage = "Binary file cannot be edited as text."
            } else {
                openFilePath = file.path
                openFileName = file.name
                editorContent = file.content
                originalEditorContent = file.content
                activeTab = .code
            }
        } catch {
            editorMessage = error.localizedDescription
        }
        isLoadingFile = false
    }

    func saveCurrentFile() async {
        guard !openFilePath.isEmpty, let token = activeProfile?.token else { return }
        isSavingFile = true
        editorMessage = nil
        do {
            let saved = try await client.writeFile(path: openFilePath, content: editorContent, token: token)
            originalEditorContent = saved.content
            editorMessage = "Saved to Windows PC"
            await refreshGitStatus()
        } catch {
            editorMessage = "Save failed: \(error.localizedDescription)"
        }
        isSavingFile = false
    }

    func runTerminalCommand(_ command: String) async {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let token = activeProfile?.token else { return }
        isRunningCommand = true
        let cwd = activeWorkspace.isEmpty ? (hostInfo?.defaultWorkspace ?? "C:\\") : activeWorkspace
        do {
            let res = try await client.execTerminal(cwd: cwd, command: trimmed, token: token)
            terminalLogs.append(TerminalLogEntry(
                command: trimmed,
                cwd: res.cwd,
                output: res.stdout,
                stderr: res.stderr,
                exitCode: res.exitCode,
                duration: res.durationSeconds
            ))
        } catch {
            terminalLogs.append(TerminalLogEntry(
                command: trimmed,
                cwd: cwd,
                output: "",
                stderr: error.localizedDescription,
                exitCode: -1,
                duration: 0
            ))
        }
        isRunningCommand = false
    }

    private func handleWsEvent(type: String, payload: [String: Any]) {
        guard let sessionId = payload["sessionId"] as? String else { return }

        if type == "agent.turn_started" {
            let turnId = payload["turnId"] as? String ?? UUID().uuidString
            let prompt = payload["prompt"] as? String ?? ""
            let workspace = payload["workspacePath"] as? String ?? activeWorkspace
            let model = payload["model"] as? String ?? selectedModel
            let mode = payload["mode"] as? String ?? selectedMode.rawValue

            if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[idx].isRunning = true
                if !sessions[idx].turns.contains(where: { $0.id == turnId }) {
                    let turn = SessionTurn(
                        id: turnId,
                        prompt: prompt,
                        attachedFiles: [],
                        responseText: "",
                        thinkingText: "",
                        status: "running",
                        durationSeconds: 0,
                        usage: nil,
                        startedAt: nil,
                        toolSteps: []
                    )
                    sessions[idx].turns.append(turn)
                    if sessions[idx].turns.count == 1 && !prompt.isEmpty {
                        sessions[idx].title = String(prompt.prefix(48))
                    }
                }
            } else {
                let newSession = SessionRecord(
                    id: sessionId,
                    agyConversationId: nil,
                    title: String(prompt.prefix(48)),
                    workspacePath: workspace,
                    model: model,
                    mode: mode,
                    createdAt: nil,
                    updatedAt: nil,
                    isRunning: true,
                    turns: [
                        SessionTurn(
                            id: turnId,
                            prompt: prompt,
                            attachedFiles: [],
                            responseText: "",
                            thinkingText: "",
                            status: "running",
                            durationSeconds: 0,
                            usage: nil,
                            startedAt: nil,
                            toolSteps: []
                        )
                    ]
                )
                sessions.insert(newSession, at: 0)
            }
            if activeSessionId == nil { activeSessionId = sessionId }
            return
        }

        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              let turnId = payload["turnId"] as? String,
              let tIdx = sessions[sIdx].turns.firstIndex(where: { $0.id == turnId }) else {
            return
        }

        switch type {
        case "agent.text_delta":
            if let delta = payload["delta"] as? String {
                sessions[sIdx].turns[tIdx].responseText += delta
            }

        case "agent.thinking_delta":
            if let delta = payload["delta"] as? String {
                sessions[sIdx].turns[tIdx].thinkingText += delta
            }

        case "agent.tool_step":
            if let stepDict = payload["step"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: stepDict),
               let step = try? JSONDecoder().decode(AgentToolStep.self, from: data) {
                if let existingIdx = sessions[sIdx].turns[tIdx].toolSteps.firstIndex(where: { $0.stepIndex == step.stepIndex }) {
                    sessions[sIdx].turns[tIdx].toolSteps[existingIdx] = step
                } else {
                    sessions[sIdx].turns[tIdx].toolSteps.append(step)
                }
            }

        case "agent.turn_finished":
            sessions[sIdx].isRunning = false
            sessions[sIdx].turns[tIdx].status = payload["status"] as? String ?? "success"
            if let dur = payload["durationSeconds"] as? Double {
                sessions[sIdx].turns[tIdx].durationSeconds = dur
            }
            if let resp = payload["response"] as? String,
               !resp.isEmpty,
               sessions[sIdx].turns[tIdx].responseText.isEmpty {
                sessions[sIdx].turns[tIdx].responseText = resp
            }
            if let cid = payload["agyConversationId"] as? String {
                sessions[sIdx].agyConversationId = cid
            }
            if let usageDict = payload["usage"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: usageDict),
               let usage = try? JSONDecoder().decode(UsageMetrics.self, from: data) {
                sessions[sIdx].turns[tIdx].usage = usage
            }
            Task { await refreshGitStatus() }

        default:
            break
        }
    }
}
