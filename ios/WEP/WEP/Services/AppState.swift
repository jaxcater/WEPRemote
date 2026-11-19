import Foundation
import SwiftUI

enum MainSurfaceTab: String, CaseIterable {
    case chat
    case explorer
    case code
    case extensions
    case terminal
}

struct TurnNotificationEvent: Equatable {
    enum Kind: Equatable {
        case completed
        case decision
    }
    let kind: Kind
    let sessionId: String
    let turnId: String
    let sessionTitle: String
    let message: String
    let status: String
}

@MainActor
final class AppState: ObservableObject {
    private let profilesKey = "wep.host.profiles.v1"
    private let activeProfileIdKey = "wep.host.activeProfileId.v1"
    private let backgroundEnabledKey = "wep.bg.enabled.v1"
    private let notifyCompletedKey = "wep.notify.completed.v1"
    private let notifyDecisionKey = "wep.notify.decision.v1"
    private let notifyForegroundKey = "wep.notify.foreground.v1"
    private let turnSnapshotsKey = "wep.turn.snapshots.v1"
    private let pendingOfflinePromptsKey = "wep.pending.offline.prompts.v1"
    private let routePreferenceKey = "wep.route.preference.v1"

    let client = WEPClient()

    @Published var profiles: [HostProfile] = []
    @Published var activeProfile: HostProfile?
    @Published var routePreference: RoutePreference = .auto {
        didSet {
            client.routePreference = routePreference
            UserDefaults.standard.set(routePreference.rawValue, forKey: routePreferenceKey)
        }
    }

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

    // Background execution, notifications, & prompt queue
    @Published var backgroundExecutionEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(backgroundExecutionEnabled, forKey: backgroundEnabledKey)
            if !backgroundExecutionEnabled {
                BackgroundManager.shared.cancelAllScheduledTasks()
            }
        }
    }
    @Published var notifyOnTaskCompleted: Bool = true {
        didSet { UserDefaults.standard.set(notifyOnTaskCompleted, forKey: notifyCompletedKey) }
    }
    @Published var notifyOnDecisionNeeded: Bool = true {
        didSet { UserDefaults.standard.set(notifyOnDecisionNeeded, forKey: notifyDecisionKey) }
    }
    @Published var notifyWhenInForeground: Bool = false {
        didSet { UserDefaults.standard.set(notifyWhenInForeground, forKey: notifyForegroundKey) }
    }
    @Published var pendingOfflinePrompts: [PendingPromptItem] = []
    @Published var isAppInBackground = false

    private var turnSnapshots: [String: TurnStateSnapshot] = [:]
    private var notifiedCompletedTurnIds: Set<String> = []
    private var notifiedDecisionTurnIds: Set<String> = []

    var hasAnyRunningOrQueuedTasks: Bool {
        sessions.contains(where: { $0.isRunning || $0.turns.contains(where: { $0.isRunning || $0.isQueued }) })
    }

    var totalQueuedPromptCount: Int {
        sessions.reduce(0) { $0 + $1.queuedTurnCount } + pendingOfflinePrompts.count
    }

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
        loadPreferencesAndSnapshots()
        loadProfiles()
        wireWebSocketEvents()
        wireNotificationsAndBackground()

        if let profile = activeProfile {
            Task { await connect(to: profile) }
        } else {
            showPairingSheet = true
        }
    }

    private func loadPreferencesAndSnapshots() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: backgroundEnabledKey) != nil {
            backgroundExecutionEnabled = defaults.bool(forKey: backgroundEnabledKey)
        }
        if defaults.object(forKey: notifyCompletedKey) != nil {
            notifyOnTaskCompleted = defaults.bool(forKey: notifyCompletedKey)
        }
        if defaults.object(forKey: notifyDecisionKey) != nil {
            notifyOnDecisionNeeded = defaults.bool(forKey: notifyDecisionKey)
        }
        if defaults.object(forKey: notifyForegroundKey) != nil {
            notifyWhenInForeground = defaults.bool(forKey: notifyForegroundKey)
        }
        if let rawPref = defaults.string(forKey: routePreferenceKey),
           let pref = RoutePreference(rawValue: rawPref) {
            routePreference = pref
            client.routePreference = pref
        }
        if let data = defaults.data(forKey: turnSnapshotsKey),
           let decoded = try? JSONDecoder().decode([String: TurnStateSnapshot].self, from: data) {
            turnSnapshots = decoded
        }
        if let data = defaults.data(forKey: pendingOfflinePromptsKey),
           let decoded = try? JSONDecoder().decode([PendingPromptItem].self, from: data) {
            pendingOfflinePrompts = decoded
        }
    }

    private func saveTurnSnapshots() {
        if let data = try? JSONEncoder().encode(turnSnapshots) {
            UserDefaults.standard.set(data, forKey: turnSnapshotsKey)
        }
    }

    private func savePendingOfflinePrompts() {
        if let data = try? JSONEncoder().encode(pendingOfflinePrompts) {
            UserDefaults.standard.set(data, forKey: pendingOfflinePromptsKey)
        }
    }

    private func wireNotificationsAndBackground() {
        let nm = NotificationManager.shared
        nm.onOpenSession = { [weak self] sessionId in
            guard let self else { return }
            if let session = self.sessions.first(where: { $0.id == sessionId }) {
                self.selectSession(session)
            } else {
                self.activeSessionId = sessionId
                self.activeTab = .chat
                Task { await self.refreshHostData() }
            }
        }
        nm.onApproveDecision = { [weak self] sessionId, _ in
            guard let self else { return }
            Task {
                await self.approveDecisionAndContinue(sessionId: sessionId)
            }
        }
        nm.shouldPresentForegroundBanner = { [weak self] sessionId in
            guard let self else { return true }
            if self.isAppInBackground { return true }
            if self.notifyWhenInForeground { return true }
            return self.activeTab != .chat || self.activeSessionId != sessionId
        }

        BackgroundManager.shared.updateRefreshHandler { [weak self] in
            guard let self else { return false }
            return await self.performBackgroundRefresh()
        }
    }

    private func wireWebSocketEvents() {
        client.onConnectionStateChange = { [weak self] connected, route in
            Task { @MainActor in
                self?.isConnected = connected
                self?.connectionRoute = route
                if connected {
                    await self?.flushPendingOfflinePrompts()
                }
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

    func setRoutePreference(_ pref: RoutePreference) async {
        routePreference = pref
        client.routePreference = pref
        if let profile = activeProfile {
            await connect(to: profile)
        }
    }

    func connect(to profile: HostProfile) async {
        activeProfile = profile
        client.updateActiveProfile(profile)
        saveProfiles()
        isConnecting = true
        connectionError = nil

        do {
            try await client.resolveAndConnect(profile: profile)
            self.isConnected = true
            self.connectionRoute = client.activeRouteLabel
            await refreshHostData()
        } catch {
            connectionError = error.localizedDescription
            isConnected = false
            connectionRoute = client.activeRouteLabel
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
                let freshTunnel = WEPClient.normalizeBaseURL(info.tunnelUrl, isTunnel: true)
                let freshLan = WEPClient.normalizeBaseURL(info.lanUrl, isTunnel: false)
                if !freshTunnel.isEmpty, freshTunnel != current.tunnelUrl {
                    current.tunnelUrl = freshTunnel
                    updated = true
                }
                if !freshLan.isEmpty, freshLan != current.lanUrl {
                    current.lanUrl = freshLan
                    updated = true
                }
                if updated {
                    if let idx = profiles.firstIndex(where: { $0.id == current.id }) {
                        profiles[idx] = current
                    }
                    activeProfile = current
                    client.updateActiveProfile(current)
                    saveProfiles()
                }
            }

            self.isConnected = true
            self.connectionRoute = client.activeRouteLabel
            self.connectionError = nil

            let loadedSessions = try await client.listSessions(token: token)
            applyLoadedSessions(loadedSessions, notifyChanges: true)
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

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            isAppInBackground = true
            if backgroundExecutionEnabled {
                if hasAnyRunningOrQueuedTasks || isConnected {
                    BackgroundManager.shared.beginImmediateBackgroundGraceTask { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            BackgroundManager.shared.scheduleBackgroundRefresh(hasActiveWork: self.hasAnyRunningOrQueuedTasks)
                        }
                    }
                }
                BackgroundManager.shared.scheduleBackgroundRefresh(hasActiveWork: hasAnyRunningOrQueuedTasks)
            }
        case .active:
            isAppInBackground = false
            BackgroundManager.shared.endImmediateBackgroundGraceTask()
            Task {
                await NotificationManager.shared.refreshAuthorizationStatus()
                await syncAfterForeground()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func syncAfterForeground() async {
        guard let profile = activeProfile else { return }
        if !isConnected {
            await connect(to: profile)
        } else {
            await refreshHostData()
        }
        await flushPendingOfflinePrompts()
    }

    func performBackgroundRefresh() async -> Bool {
        guard backgroundExecutionEnabled, let profile = activeProfile else {
            return false
        }

        do {
            _ = try await client.resolveReachableBaseURL(profile: profile)
            let loadedSessions = try await client.listSessions(token: profile.token)
            applyLoadedSessions(loadedSessions, notifyChanges: true)
            await flushPendingOfflinePrompts()
            return hasAnyRunningOrQueuedTasks
        } catch {
            return false
        }
    }

    private func applyLoadedSessions(_ loadedSessions: [SessionRecord], notifyChanges: Bool) {
        if notifyChanges && !turnSnapshots.isEmpty {
            let events = Self.detectTurnNotifications(previous: turnSnapshots, updated: loadedSessions)
            for ev in events {
                dispatchNotificationEvent(ev)
            }
        }
        self.sessions = loadedSessions
        var nextSnapshots: [String: TurnStateSnapshot] = [:]
        for session in loadedSessions {
            for turn in session.turns {
                nextSnapshots[turn.id] = TurnStateSnapshot(
                    status: turn.status,
                    needsDecision: turn.requiresUserDecision
                )
            }
        }
        self.turnSnapshots = nextSnapshots
        saveTurnSnapshots()
    }

    nonisolated static func detectTurnNotifications(
        previous: [String: TurnStateSnapshot],
        updated: [SessionRecord]
    ) -> [TurnNotificationEvent] {
        var events: [TurnNotificationEvent] = []
        for session in updated {
            let title = session.title.isEmpty ? "Conversation" : session.title
            for turn in session.turns {
                let prev = previous[turn.id]
                let wasRunningOrNew = (prev == nil) || prev?.status == "running" || prev?.status == "queued"

                if turn.requiresUserDecision && prev?.needsDecision != true {
                    events.append(TurnNotificationEvent(
                        kind: .decision,
                        sessionId: session.id,
                        turnId: turn.id,
                        sessionTitle: title,
                        message: turn.decisionPrompt ?? turn.responseText,
                        status: turn.status
                    ))
                } else if wasRunningOrNew && turn.isTerminal && !turn.requiresUserDecision && turn.status != "cancelled" {
                    events.append(TurnNotificationEvent(
                        kind: .completed,
                        sessionId: session.id,
                        turnId: turn.id,
                        sessionTitle: title,
                        message: turn.responseText,
                        status: turn.status
                    ))
                }
            }
        }
        return events
    }

    private func dispatchNotificationEvent(_ event: TurnNotificationEvent) {
        switch event.kind {
        case .decision:
            guard notifyOnDecisionNeeded else { return }
            guard notifiedDecisionTurnIds.insert(event.turnId).inserted else { return }
            NotificationManager.shared.notifyDecisionNeeded(
                sessionId: event.sessionId,
                turnId: event.turnId,
                sessionTitle: event.sessionTitle,
                question: event.message
            )
        case .completed:
            guard notifyOnTaskCompleted else { return }
            guard notifiedCompletedTurnIds.insert(event.turnId).inserted else { return }
            if shouldDispatchCompletionNotification(for: event.sessionId) {
                NotificationManager.shared.notifyTaskCompleted(
                    sessionId: event.sessionId,
                    turnId: event.turnId,
                    sessionTitle: event.sessionTitle,
                    summary: event.message,
                    status: event.status
                )
            }
        }
    }

    private func shouldDispatchCompletionNotification(for sessionId: String) -> Bool {
        if isAppInBackground || notifyWhenInForeground { return true }
        return activeTab != .chat || activeSessionId != sessionId
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

    func sendPrompt(_ prompt: String, attachedFiles: [String] = [], inNewParallelSession: Bool = false) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let workspace = activeWorkspace.isEmpty ? (hostInfo?.defaultWorkspace ?? "") : activeWorkspace

        guard let token = activeProfile?.token else { return }

        if !isConnected {
            let item = PendingPromptItem(
                id: UUID().uuidString,
                sessionId: inNewParallelSession ? nil : activeSessionId,
                engine: selectedEngine.rawValue,
                workspacePath: workspace,
                prompt: trimmed,
                model: selectedModel,
                effort: selectedEffort,
                mode: selectedMode.rawValue,
                skipPermissions: skipPermissions,
                attachedFiles: attachedFiles,
                createdAt: Date()
            )
            pendingOfflinePrompts.append(item)
            savePendingOfflinePrompts()
            return
        }

        do {
            var targetSessionId = inNewParallelSession ? nil : activeSessionId
            if targetSessionId == nil {
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
                targetSessionId = created.id
            }

            _ = try await client.startAgent(
                sessionId: targetSessionId,
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

    func flushPendingOfflinePrompts() async {
        guard isConnected, !pendingOfflinePrompts.isEmpty, let token = activeProfile?.token else { return }
        let items = pendingOfflinePrompts
        pendingOfflinePrompts.removeAll()
        savePendingOfflinePrompts()

        for (index, item) in items.enumerated() {
            do {
                var targetSessionId = item.sessionId
                if targetSessionId == nil {
                    let created = try await client.createSession(
                        engine: item.engine,
                        workspacePath: item.workspacePath,
                        model: item.model,
                        effort: item.effort,
                        mode: item.mode,
                        token: token
                    )
                    sessions.insert(created, at: 0)
                    if activeSessionId == nil {
                        activeSessionId = created.id
                    }
                    targetSessionId = created.id
                }

                _ = try await client.startAgent(
                    sessionId: targetSessionId,
                    engine: item.engine,
                    workspacePath: item.workspacePath,
                    prompt: item.prompt,
                    model: item.model,
                    effort: item.effort,
                    mode: item.mode,
                    skipPermissions: item.skipPermissions,
                    attachedFiles: item.attachedFiles,
                    token: token
                )
            } catch {
                let remaining = Array(items[index...])
                pendingOfflinePrompts.insert(contentsOf: remaining, at: 0)
                savePendingOfflinePrompts()
                connectionError = error.localizedDescription
                break
            }
        }
    }

    func removePendingOfflinePrompt(id: String) {
        pendingOfflinePrompts.removeAll(where: { $0.id == id })
        savePendingOfflinePrompts()
    }

    func cancelActiveTurn(clearQueue: Bool = false) async {
        guard let sid = activeSessionId, let token = activeProfile?.token else { return }
        try? await client.cancelAgent(sessionId: sid, clearQueue: clearQueue, token: token)
    }

    func cancelTurn(sessionId: String, turnId: String) async {
        guard let token = activeProfile?.token else { return }
        try? await client.cancelTurn(sessionId: sessionId, turnId: turnId, token: token)
    }

    func approveDecisionAndContinue(sessionId: String, customReply: String = "Approved. Please proceed.") async {
        if let session = sessions.first(where: { $0.id == sessionId }) {
            selectSession(session)
        } else {
            activeSessionId = sessionId
            activeTab = .chat
        }
        await sendPrompt(customReply)
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
        if type == "host.tunnel_updated" || type == "host.connected" {
            let freshTunnel = WEPClient.normalizeBaseURL(payload["tunnelUrl"] as? String, isTunnel: true)
            let freshLan = WEPClient.normalizeBaseURL(payload["lanUrl"] as? String, isTunnel: false)
            if var current = activeProfile {
                var updated = false
                if !freshTunnel.isEmpty, freshTunnel != current.tunnelUrl {
                    current.tunnelUrl = freshTunnel
                    updated = true
                }
                if !freshLan.isEmpty, freshLan != current.lanUrl {
                    current.lanUrl = freshLan
                    updated = true
                }
                if updated {
                    if let idx = profiles.firstIndex(where: { $0.id == current.id }) {
                        profiles[idx] = current
                    }
                    activeProfile = current
                    client.updateActiveProfile(current)
                    saveProfiles()
                }
            }
            return
        }

        guard let sessionId = payload["sessionId"] as? String else { return }

        if type == "agent.turn_queued" || type == "agent.turn_started" {
            let isQueued = (type == "agent.turn_queued")
            let targetStatus = isQueued ? "queued" : "running"
            let turnId = payload["turnId"] as? String ?? UUID().uuidString
            let prompt = payload["prompt"] as? String ?? ""
            let engine = payload["engine"] as? String ?? selectedEngine.rawValue
            let workspace = payload["workspacePath"] as? String ?? activeWorkspace
            let model = payload["model"] as? String ?? selectedModel
            let effort = payload["effort"] as? String ?? selectedEffort
            let mode = payload["mode"] as? String ?? selectedMode.rawValue
            let files = payload["attachedFiles"] as? [String] ?? []

            if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[idx].isRunning = true
                if !isQueued {
                    sessions[idx].engine = engine
                    sessions[idx].model = model
                    sessions[idx].effort = effort
                }
                if let existingTurnIdx = sessions[idx].turns.firstIndex(where: { $0.id == turnId }) {
                    sessions[idx].turns[existingTurnIdx].status = targetStatus
                } else {
                    let turn = SessionTurn(
                        id: turnId,
                        engine: engine,
                        model: model,
                        effort: effort,
                        prompt: prompt,
                        attachedFiles: files,
                        responseText: "",
                        thinkingText: "",
                        status: targetStatus,
                        needsDecision: false,
                        decisionPrompt: nil,
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
                            attachedFiles: files,
                            responseText: "",
                            thinkingText: "",
                            status: targetStatus,
                            needsDecision: false,
                            decisionPrompt: nil,
                            durationSeconds: 0,
                            usage: nil,
                            startedAt: nil,
                            toolSteps: []
                        )
                    ]
                )
                sessions.insert(newSession, at: 0)
            }
            turnSnapshots[turnId] = TurnStateSnapshot(status: targetStatus, needsDecision: false)
            saveTurnSnapshots()
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

        case "agent.decision_required":
            let decisionPrompt = payload["decisionPrompt"] as? String ?? "User decision required to continue."
            sessions[sIdx].turns[tIdx].needsDecision = true
            sessions[sIdx].turns[tIdx].decisionPrompt = decisionPrompt
            turnSnapshots[turnId] = TurnStateSnapshot(status: sessions[sIdx].turns[tIdx].status, needsDecision: true)
            saveTurnSnapshots()
            dispatchNotificationEvent(TurnNotificationEvent(
                kind: .decision,
                sessionId: sessionId,
                turnId: turnId,
                sessionTitle: sessions[sIdx].title,
                message: decisionPrompt,
                status: sessions[sIdx].turns[tIdx].status
            ))

        case "agent.turn_finished":
            let status = payload["status"] as? String ?? "success"
            let needsDecision = payload["needsDecision"] as? Bool ?? sessions[sIdx].turns[tIdx].needsDecision ?? false
            let decisionPrompt = payload["decisionPrompt"] as? String ?? sessions[sIdx].turns[tIdx].decisionPrompt
            let hasQueuedNext = payload["hasQueuedNext"] as? Bool ?? false

            sessions[sIdx].turns[tIdx].status = status
            sessions[sIdx].turns[tIdx].needsDecision = needsDecision
            sessions[sIdx].turns[tIdx].decisionPrompt = decisionPrompt
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

            let stillHasActive = hasQueuedNext || sessions[sIdx].turns.contains(where: { $0.isRunning || $0.isQueued })
            sessions[sIdx].isRunning = stillHasActive

            turnSnapshots[turnId] = TurnStateSnapshot(status: status, needsDecision: needsDecision)
            saveTurnSnapshots()

            let sessionTitle = sessions[sIdx].title
            let summaryText = sessions[sIdx].turns[tIdx].responseText
            if needsDecision {
                dispatchNotificationEvent(TurnNotificationEvent(
                    kind: .decision,
                    sessionId: sessionId,
                    turnId: turnId,
                    sessionTitle: sessionTitle,
                    message: decisionPrompt ?? summaryText,
                    status: status
                ))
            } else if status != "cancelled" {
                dispatchNotificationEvent(TurnNotificationEvent(
                    kind: .completed,
                    sessionId: sessionId,
                    turnId: turnId,
                    sessionTitle: sessionTitle,
                    message: summaryText,
                    status: status
                ))
            }

            Task { await refreshGitStatus() }

        default:
            break
        }
    }
}
