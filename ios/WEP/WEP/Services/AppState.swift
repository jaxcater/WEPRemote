import Foundation
import SwiftUI

enum MainSurfaceTab: String, CaseIterable {
    case chat
    case explorer
    case code
    case extensions
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
    @Published var cursorLive: CursorLiveState?
    @Published var extensions: [ExtensionItem] = []
    @Published var codexThreads: [CodexThreadSummary] = []

    @Published var models: [AiModelOption] = [
        AiModelOption(id: "gemini-4-hydrogen", displayName: "Gemini 4 Hydrogen", engine: "antigravity", baseModel: "gemini-4-hydrogen", defaultEffort: "high", supportedEfforts: ["low", "medium", "high", "xhigh"]),
        AiModelOption(id: "gemini-4-argon", displayName: "Gemini 4 Argon", engine: "antigravity", baseModel: "gemini-4-argon", defaultEffort: "high", supportedEfforts: ["low", "medium", "high"]),
        AiModelOption(id: "gemini-3.8-flash", displayName: "Gemini 3.8 Flash", engine: "antigravity", baseModel: "gemini-3.8-flash", defaultEffort: "high", supportedEfforts: ["low", "medium", "high"]),
        AiModelOption(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", engine: "antigravity", baseModel: "claude-opus-5-5", defaultEffort: "high", supportedEfforts: ["low", "medium", "high"]),
        AiModelOption(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", engine: "antigravity", baseModel: "claude-sonnet-5-5", defaultEffort: "high", supportedEfforts: ["low", "medium", "high"]),
        AiModelOption(id: "gpt-6.1-sol", displayName: "GPT-6.1 Sol", engine: "codex", baseModel: "gpt-6.1-sol", defaultEffort: "medium", supportedEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
        AiModelOption(id: "gpt-6.1-terra", displayName: "GPT-6.1 Terra", engine: "codex", baseModel: "gpt-6.1-terra", defaultEffort: "medium", supportedEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
        AiModelOption(id: "gpt-6-astra", displayName: "GPT-6 Astra", engine: "codex", baseModel: "gpt-6-astra", defaultEffort: "medium", supportedEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"])
    ]

    @Published var activeWorkspace: String = ""
    @Published var pinnedWorkspaces: [String] = []

    // Separated Engine / Model / Reasoning Effort state
    @Published var selectedEngine: AgentEngine = .antigravity
    @Published var selectedModel: String = "gemini-4-hydrogen"
    @Published var selectedEffort: String = "high"
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

    // Git & Terminal & Extensions feedback
    @Published var gitStatus: GitStatusResponse?
    @Published var terminalLogs: [TerminalLogEntry] = []
    @Published var isRunningCommand = false
    @Published var isLoadingExtensions = false
    @Published var extensionStatusMessage: String?

    var modelsForSelectedEngine: [AiModelOption] {
        let filtered = models.filter { $0.resolvedEngine == selectedEngine }
        return filtered.isEmpty ? models : filtered
    }

    var currentModelOption: AiModelOption? {
        modelsForSelectedEngine.first(where: { $0.id == selectedModel }) ?? modelsForSelectedEngine.first
    }

    var supportedEffortsForCurrentModel: [String] {
        currentModelOption?.efforts ?? ["low", "medium", "high"]
    }

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

    func selectEngine(_ engine: AgentEngine) {
        selectedEngine = engine
        let available = modelsForSelectedEngine
        if !available.contains(where: { $0.id == selectedModel }), let first = available.first {
            selectModel(first.id)
        } else {
            clampEffortToCurrentModel()
        }
    }

    func selectModel(_ modelId: String) {
        selectedModel = modelId
        if let option = modelsForSelectedEngine.first(where: { $0.id == modelId }) {
            if !option.efforts.contains(selectedEffort) {
                selectedEffort = option.defaultEffort ?? option.efforts.first ?? "high"
            }
        }
    }

    private func clampEffortToCurrentModel() {
        let supported = supportedEffortsForCurrentModel
        if !supported.contains(selectedEffort) {
            selectedEffort = currentModelOption?.defaultEffort ?? supported.first ?? "medium"
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
            self.cursorLive = info.cursorLive
            if !info.models.isEmpty {
                self.models = info.models
                clampEffortToCurrentModel()
            }
            self.pinnedWorkspaces = info.pinnedWorkspaces
            if self.activeWorkspace.isEmpty {
                self.activeWorkspace = info.cursorLive?.activeWorkspace ?? info.defaultWorkspace
            }
            if let skip = info.defaultSkipPermissions {
                self.skipPermissions = skip
            }

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

            if let threads = try? await client.listCodexThreads(token: token) {
                self.codexThreads = threads
            }

            await refreshGitStatus()
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func syncWithActiveCursor() async {
        guard let token = activeProfile?.token else { return }
        if let live = try? await client.getCursorLive(token: token) {
            self.cursorLive = live
            if let ws = live.activeWorkspace, !ws.isEmpty {
                await openFolderAsWorkspace(ws)
            }
        }
    }

    func openInCursor(path: String) async {
        guard let token = activeProfile?.token, !path.isEmpty else { return }
        _ = try? await client.openInCursor(path: path, token: token)
    }

    func resumeCodexThread(_ thread: CodexThreadSummary) async {
        guard let token = activeProfile?.token else { return }
        let ws = activeWorkspace.isEmpty ? (cursorLive?.activeWorkspace ?? hostInfo?.defaultWorkspace ?? "") : activeWorkspace
        do {
            let codexModel = selectedEngine == .codex ? selectedModel : "gpt-6.1-sol"
            let session = try await client.importCodexThread(
                threadId: thread.id,
                title: thread.title,
                workspacePath: ws,
                model: codexModel,
                effort: selectedEffort,
                token: token
            )
            if !sessions.contains(where: { $0.id == session.id }) {
                sessions.insert(session, at: 0)
            }
            selectSession(session)
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func refreshExtensions() async {
        guard let token = activeProfile?.token else { return }
        isLoadingExtensions = true
        extensionStatusMessage = nil
        do {
            extensions = try await client.listExtensions(token: token)
        } catch {
            extensionStatusMessage = error.localizedDescription
        }
        isLoadingExtensions = false
    }

    func installExtension(id: String) async {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let token = activeProfile?.token else { return }
        isLoadingExtensions = true
        extensionStatusMessage = "Installing \(trimmed)..."
        do {
            _ = try await client.installExtension(id: trimmed, source: "cursor", token: token)
            extensionStatusMessage = "Installed \(trimmed)"
            await refreshExtensions()
        } catch {
            extensionStatusMessage = error.localizedDescription
            isLoadingExtensions = false
        }
    }

    func uninstallExtension(_ item: ExtensionItem) async {
        guard let token = activeProfile?.token else { return }
        isLoadingExtensions = true
        extensionStatusMessage = "Removing \(item.id)..."
        do {
            _ = try await client.uninstallExtension(id: item.id, source: item.source, token: token)
            extensionStatusMessage = "Removed \(item.id)"
            await refreshExtensions()
        } catch {
            extensionStatusMessage = error.localizedDescription
            isLoadingExtensions = false
        }
    }

    func updateAllExtensions() async {
        guard let token = activeProfile?.token else { return }
        isLoadingExtensions = true
        extensionStatusMessage = "Updating extensions..."
        do {
            _ = try await client.updateExtensions(token: token)
            extensionStatusMessage = "Extensions updated"
            await refreshExtensions()
        } catch {
            extensionStatusMessage = error.localizedDescription
            isLoadingExtensions = false
        }
    }

    func togglePlugin(_ item: ExtensionItem) async {
        guard item.source == "antigravity", let token = activeProfile?.token else { return }
        isLoadingExtensions = true
        do {
            _ = try await client.togglePlugin(id: item.id, enable: !item.enabled, token: token)
            await refreshExtensions()
        } catch {
            extensionStatusMessage = error.localizedDescription
            isLoadingExtensions = false
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
        if let engStr = session.engine, let eng = AgentEngine(rawValue: engStr) {
            selectedEngine = eng
        }
        if !session.workspacePath.isEmpty {
            activeWorkspace = session.workspacePath
        }
        if !session.model.isEmpty {
            selectedModel = session.model
        }
        if let eff = session.effort, !eff.isEmpty {
            selectedEffort = eff
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
            if activeSessionId == nil {
                let created = try await client.createSession(
                    engine: selectedEngine.rawValue,
                    workspacePath: workspace,
                    model: selectedModel,
                    effort: selectedEffort,
                    mode: selectedMode.rawValue,
                    token: token
                )
                sessions.insert(created, at: 0)
                activeSessionId = created.id
            }

            try await client.startAgent(
                sessionId: activeSessionId,
                engine: selectedEngine.rawValue,
                workspacePath: workspace,
                prompt: trimmed,
                model: selectedModel,
                effort: selectedEffort,
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
            let engine = payload["engine"] as? String ?? selectedEngine.rawValue
            let workspace = payload["workspacePath"] as? String ?? activeWorkspace
            let model = payload["model"] as? String ?? selectedModel
            let effort = payload["effort"] as? String ?? selectedEffort
            let mode = payload["mode"] as? String ?? selectedMode.rawValue

            if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[idx].isRunning = true
                sessions[idx].engine = engine
                sessions[idx].model = model
                sessions[idx].effort = effort
                if !sessions[idx].turns.contains(where: { $0.id == turnId }) {
                    let turn = SessionTurn(
                        id: turnId,
                        engine: engine,
                        model: model,
                        effort: effort,
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
                    engine: engine,
                    agyConversationId: nil,
                    codexThreadId: nil,
                    title: String(prompt.prefix(48)),
                    workspacePath: workspace,
                    model: model,
                    effort: effort,
                    mode: mode,
                    createdAt: nil,
                    updatedAt: nil,
                    isRunning: true,
                    turns: [
                        SessionTurn(
                            id: turnId,
                            engine: engine,
                            model: model,
                            effort: effort,
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
            if let tid = payload["codexThreadId"] as? String {
                sessions[sIdx].codexThreadId = tid
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
