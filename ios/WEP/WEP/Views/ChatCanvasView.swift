import SwiftUI

struct ChatCanvasView: View {
    @EnvironmentObject var appState: AppState

    @State private var promptText = ""
    @State private var attachedFiles: [String] = []
    @State private var showFileMentionSheet = false
    @State private var showSlashMenu = false
    @State private var sendInParallelSession = false
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let error = appState.connectionError, !appState.isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundColor(AgyTheme.warning)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(AgyTheme.textPrimary)
                        .lineLimit(2)
                    Spacer()
                    Button("Retry") {
                        if let profile = appState.activeProfile {
                            Task { await appState.connect(to: profile) }
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AgyTheme.accentCyan)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AgyTheme.warning.opacity(0.14))
            }

            if let session = appState.activeSession, !session.turns.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(session.turns) { turn in
                                TurnView(
                                    turn: turn,
                                    onCancelQueued: turn.isQueued ? {
                                        Task { await appState.cancelTurn(sessionId: session.id, turnId: turn.id) }
                                    } : nil,
                                    onApproveDecision: turn.requiresUserDecision ? {
                                        Task { await appState.approveDecisionAndContinue(sessionId: session.id) }
                                    } : nil,
                                    onReplyDecision: turn.requiresUserDecision ? {
                                        isPromptFocused = true
                                    } : nil
                                )
                                .id(turn.id)
                            }
                        }
                        .padding(14)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isPromptFocused = false
                        hideKeyboard()
                    }
                    .onChange(of: session.turns.count) { _, _ in
                        if let lastId = session.turns.last?.id {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: session.turns.last?.responseText) { _, _ in
                        if let lastId = session.turns.last?.id {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
            } else {
                emptyStudioCanvas
                    .scrollDismissesKeyboard(.interactively)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isPromptFocused = false
                        hideKeyboard()
                    }
            }

            if showSlashMenu {
                slashCommandsBar
            }

            composerPanel
        }
        .sheet(isPresented: $showFileMentionSheet) {
            FileMentionPickerSheet(
                workspacePath: appState.activeWorkspace,
                selectedFiles: $attachedFiles
            )
            .environmentObject(appState)
            .preferredColorScheme(.dark)
        }
    }

    private var emptyStudioCanvas: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 22)

                ZStack {
                    Circle()
                        .fill((appState.selectedEngine == .codex ? AgyTheme.codexGradient : AgyTheme.brandGradient).opacity(0.20))
                        .frame(width: 72, height: 72)
                    Image(systemName: appState.selectedEngine.icon)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(appState.selectedEngine == .codex ? AgyTheme.codexGradient : AgyTheme.brandGradient)
                }

                VStack(spacing: 6) {
                    Text("\(appState.selectedEngine.displayName) Remote")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(AgyTheme.textPrimary)
                    Text(appState.activeWorkspace.isEmpty
                         ? "Pair your Windows PC or sync with your open Cursor window"
                         : appState.activeWorkspace)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(AgyTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }

                if let cursorWs = appState.cursorLive?.activeWorkspace,
                   appState.cursorLive?.isCursorRunning == true,
                   cursorWs.caseInsensitiveCompare(appState.activeWorkspace) != .orderedSame {
                    Button {
                        Task { await appState.syncWithActiveCursor() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "cursorarrow.rays")
                            Text("Sync to Active Cursor: \((cursorWs.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent)")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundColor(AgyTheme.accentCodex)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(AgyTheme.accentCodex.opacity(0.14))
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgyTheme.accentCodex.opacity(0.4), lineWidth: 1))
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    starterCard(icon: "folder.badge.gearshape", title: "Open Folder", subtitle: "Browse Windows drives") {
                        appState.activeTab = .explorer
                    }
                    starterCard(icon: "doc.text.magnifyingglass", title: "Explain Repo", subtitle: "Map architecture") {
                        promptText = "Analyze this workspace folder and explain its architecture, entry points, and build setup."
                    }
                    starterCard(icon: "puzzlepiece.extension", title: "Extensions", subtitle: "Manage Cursor & AGY") {
                        appState.activeTab = .extensions
                    }
                    starterCard(icon: "terminal", title: "Remote Shell", subtitle: "Run PowerShell commands") {
                        appState.activeTab = .terminal
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
            .padding(.bottom, 20)
        }
    }

    private func starterCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(AgyTheme.accentCyan)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(AgyTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(AgyTheme.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(AgyTheme.bgCard)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgyTheme.borderSubtle, lineWidth: 1))
        }
    }

    private var slashCommandsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SlashCommandItem.builtIn) { item in
                    Button {
                        promptText = item.template
                        showSlashMenu = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.command)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(AgyTheme.accentCyan)
                            Text(item.description)
                                .font(.system(size: 10.5))
                                .foregroundColor(AgyTheme.textSecondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(AgyTheme.bgElevated)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AgyTheme.borderSubtle, lineWidth: 1))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(AgyTheme.bgSidebar)
    }

    private var composerPanel: some View {
        VStack(spacing: 7) {
            if !appState.pendingOfflinePrompts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(appState.pendingOfflinePrompts) { pending in
                            HStack(spacing: 5) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 10))
                                Text("Offline Queue: \(pending.prompt)")
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Button {
                                    appState.removePendingOfflinePrompt(id: pending.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                }
                            }
                            .foregroundColor(AgyTheme.warning)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AgyTheme.warning.opacity(0.14))
                            .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            if appState.currentTurnIsRunning {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        ProgressView()
                            .scaleEffect(0.65)
                            .tint(AgyTheme.accentCyan)
                        Text(sendInParallelSession ? "Parallel mode: sends in new chat" : "Running: new prompts queue next")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AgyTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let qCount = appState.activeSession?.queuedTurnCount, qCount > 0 {
                        Text("\(qCount) queued")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(AgyTheme.accentCyan)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AgyTheme.accentCyan.opacity(0.14))
                            .cornerRadius(5)
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            sendInParallelSession.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: sendInParallelSession ? "arrow.branch" : "text.append")
                                .font(.system(size: 10))
                            Text(sendInParallelSession ? "Parallel" : "Queue")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundColor(sendInParallelSession ? AgyTheme.accentCodex : AgyTheme.accentIndigo)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((sendInParallelSession ? AgyTheme.accentCodex : AgyTheme.accentIndigo).opacity(0.16))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 12)
            }

            if !attachedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachedFiles, id: \.self) { file in
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 10))
                                Text((file.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent)
                                    .font(.system(size: 11, design: .monospaced))
                                Button {
                                    attachedFiles.removeAll(where: { $0 == file })
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                }
                            }
                            .foregroundColor(AgyTheme.accentCyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AgyTheme.accentCyan.opacity(0.14))
                            .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            // BAR 1: Separated Engine + Model Selector Bar
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(AgentEngine.allCases) { eng in
                        let active = appState.selectedEngine == eng
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                appState.selectEngine(eng)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: eng.icon)
                                    .font(.system(size: 10))
                                Text(eng.displayName)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundColor(active ? .white : AgyTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(active
                                ? (eng == .codex ? AnyShapeStyle(AgyTheme.codexGradient) : AnyShapeStyle(AgyTheme.brandGradient))
                                : AnyShapeStyle(Color.clear))
                            .cornerRadius(7)
                        }
                    }
                }
                .padding(2)
                .background(AgyTheme.bgCard)
                .cornerRadius(9)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(AgyTheme.borderSubtle, lineWidth: 1))

                // Separate Model Selector Pill
                Menu {
                    ForEach(appState.modelsForSelectedEngine) { m in
                        Button {
                            appState.selectModel(m.id)
                        } label: {
                            HStack {
                                Text(m.displayName)
                                if m.id == appState.selectedModel {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 11))
                            .foregroundColor(AgyTheme.accentCyan)
                        Text(appState.currentModelOption?.displayName ?? appState.selectedModel)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(AgyTheme.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(AgyTheme.textMuted)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AgyTheme.bgCard)
                    .cornerRadius(9)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(AgyTheme.borderSubtle, lineWidth: 1))
                }

                Spacer()
            }
            .padding(.horizontal, 12)

            // BAR 2: Dedicated Reasoning Effort Pill Strip (low, medium, high, xhigh, max, ultra)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.needle")
                            .font(.system(size: 10))
                        Text("Effort")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundColor(AgyTheme.textMuted)
                    .padding(.trailing, 2)

                    ForEach(appState.supportedEffortsForCurrentModel, id: \.self) { effRaw in
                        let eff = ReasoningEffort(rawValue: effRaw)
                        let selected = appState.selectedEffort == effRaw
                        let tint = eff?.color ?? AgyTheme.accentIndigo
                        Button {
                            withAnimation(.easeInOut(duration: 0.12)) {
                                appState.selectedEffort = effRaw
                            }
                        } label: {
                            Text(eff?.label ?? effRaw.capitalized)
                                .font(.system(size: 11, weight: selected ? .bold : .medium, design: .monospaced))
                                .foregroundColor(selected ? .white : AgyTheme.textSecondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(selected ? tint.opacity(0.85) : AgyTheme.bgCard)
                                .cornerRadius(7)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(selected ? tint : AgyTheme.borderSubtle, lineWidth: 1)
                                )
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            // Input Box
            VStack(spacing: 8) {
                TextField("Ask \(appState.selectedEngine.displayName) to edit, debug, or build...", text: $promptText, axis: .vertical)
                    .focused($isPromptFocused)
                    .lineLimit(1...6)
                    .font(.system(size: 14.5))
                    .foregroundColor(AgyTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                HStack(spacing: 8) {
                    Button {
                        isPromptFocused = false
                        hideKeyboard()
                        showFileMentionSheet = true
                    } label: {
                        Text("@")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(AgyTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(AgyTheme.bgElevated)
                            .cornerRadius(7)
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showSlashMenu.toggle()
                        }
                    } label: {
                        Text("/")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(showSlashMenu ? AgyTheme.accentCyan : AgyTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(AgyTheme.bgElevated)
                            .cornerRadius(7)
                    }

                    // Execution mode pill
                    Menu {
                        ForEach(ExecutionMode.allCases) { mode in
                            Button {
                                appState.selectedMode = mode
                            } label: {
                                Label(mode.label, systemImage: mode.icon)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: appState.selectedMode.icon)
                                .font(.system(size: 10))
                            Text(appState.selectedMode.label)
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundColor(AgyTheme.accentIndigo)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(AgyTheme.accentIndigo.opacity(0.14))
                        .cornerRadius(7)
                    }

                    Spacer()

                    if isPromptFocused {
                        Button {
                            isPromptFocused = false
                            hideKeyboard()
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(AgyTheme.accentCyan)
                                .frame(width: 32, height: 32)
                                .background(AgyTheme.bgElevated)
                                .clipShape(Circle())
                        }
                    }

                    if appState.currentTurnIsRunning {
                        Button {
                            Task { await appState.cancelActiveTurn() }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .background(AgyTheme.danger)
                                .clipShape(Circle())
                        }
                    }

                    let canSend = !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button {
                        let toSend = promptText
                        let files = attachedFiles
                        let useParallel = appState.currentTurnIsRunning && sendInParallelSession
                        promptText = ""
                        attachedFiles = []
                        showSlashMenu = false
                        isPromptFocused = false
                        hideKeyboard()
                        Task { await appState.sendPrompt(toSend, attachedFiles: files, inNewParallelSession: useParallel) }
                    } label: {
                        Image(systemName: appState.currentTurnIsRunning ? (sendInParallelSession ? "arrow.branch" : "text.badge.plus") : "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(
                                !canSend
                                    ? AnyShapeStyle(AgyTheme.bgElevated)
                                    : (appState.selectedEngine == .codex ? AnyShapeStyle(AgyTheme.codexGradient) : AnyShapeStyle(AgyTheme.brandGradient))
                            )
                            .clipShape(Circle())
                    }
                    .disabled(!canSend)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .background(AgyTheme.bgCard)
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AgyTheme.borderSubtle, lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .padding(.top, 6)
        .background(AgyTheme.bgSidebar.opacity(0.85))
    }
}

struct TurnView: View {
    let turn: SessionTurn
    var onCancelQueued: (() -> Void)? = nil
    var onApproveDecision: (() -> Void)? = nil
    var onReplyDecision: (() -> Void)? = nil
    @State private var showThinking = false

    private var engine: AgentEngine {
        AgentEngine(rawValue: turn.engine ?? "antigravity") ?? .antigravity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 36)
                Text(turn.prompt)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(AgyTheme.accentIndigo.opacity(0.32))
                    .cornerRadius(13)
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(AgyTheme.accentIndigo.opacity(0.5), lineWidth: 1))
            }

            if !turn.thinkingText.isEmpty {
                DisclosureGroup(isExpanded: $showThinking) {
                    Text(turn.thinkingText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(AgyTheme.textSecondary)
                        .padding(.top, 6)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                            .foregroundColor(AgyTheme.accentIndigo)
                        Text("Reasoning (\(turn.effort ?? "auto"))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AgyTheme.textSecondary)
                    }
                }
                .padding(10)
                .background(AgyTheme.bgCard)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgyTheme.borderSubtle, lineWidth: 1))
            }

            ForEach(turn.toolSteps) { step in
                ToolStepCard(step: step)
            }

            if !turn.responseText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: engine.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(engine == .codex ? AgyTheme.codexGradient : AgyTheme.brandGradient)
                        Text(engine.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AgyTheme.textSecondary)
                        if let m = turn.model, !m.isEmpty {
                            Text("• \(m)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(AgyTheme.textMuted)
                                .lineLimit(1)
                        }
                        if let e = turn.effort, !e.isEmpty {
                            Text(e.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(ReasoningEffort(rawValue: e)?.color ?? AgyTheme.accentCyan)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(AgyTheme.bgElevated)
                                .cornerRadius(4)
                        }
                        Spacer()
                        Button {
                            UIPasteboard.general.string = turn.responseText
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(AgyTheme.textMuted)
                        }
                    }

                    Text(LocalizedStringKey(turn.responseText))
                        .font(.system(size: 14))
                        .foregroundColor(AgyTheme.textPrimary)
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(AgyTheme.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgyTheme.borderSubtle, lineWidth: 1))
            } else if turn.status == "running" {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(engine == .codex ? AgyTheme.accentCodex : AgyTheme.accentCyan)
                    Text("\(engine.displayName) is working on your PC...")
                        .font(.system(size: 12.5))
                        .foregroundColor(AgyTheme.textSecondary)
                }
                .padding(10)
            } else if turn.status == "queued" {
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 13))
                        .foregroundColor(AgyTheme.accentCyan)
                    Text("Queued — will start automatically when current prompt finishes")
                        .font(.system(size: 12))
                        .foregroundColor(AgyTheme.textSecondary)
                    Spacer()
                    if let onCancelQueued {
                        Button {
                            onCancelQueued()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundColor(AgyTheme.textMuted)
                        }
                    }
                }
                .padding(10)
                .background(AgyTheme.accentCyan.opacity(0.10))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgyTheme.accentCyan.opacity(0.3), lineWidth: 1))
            }

            if turn.requiresUserDecision {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 12))
                            .foregroundColor(AgyTheme.warning)
                        Text("Decision Needed to Continue")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(AgyTheme.warning)
                    }

                    if let q = turn.decisionPrompt, !q.isEmpty {
                        Text(q)
                            .font(.system(size: 12.5))
                            .foregroundColor(AgyTheme.textPrimary)
                    }

                    HStack(spacing: 8) {
                        if let onApproveDecision {
                            Button {
                                onApproveDecision()
                            } label: {
                                Label("Approve & Continue", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(AgyTheme.accentIndigo)
                                    .cornerRadius(8)
                            }
                        }
                        if let onReplyDecision {
                            Button {
                                onReplyDecision()
                            } label: {
                                Label("Reply", systemImage: "bubble.left.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(AgyTheme.textPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(AgyTheme.bgElevated)
                                    .cornerRadius(8)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AgyTheme.borderSubtle, lineWidth: 1))
                            }
                        }
                    }
                }
                .padding(11)
                .background(AgyTheme.warning.opacity(0.12))
                .cornerRadius(11)
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(AgyTheme.warning.opacity(0.45), lineWidth: 1))
            }

            if turn.isTerminal {
                HStack(spacing: 10) {
                    Label(turn.status.uppercased(), systemImage: turn.status == "success" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(turn.status == "success" ? AgyTheme.success : (turn.status == "cancelled" ? AgyTheme.textMuted : AgyTheme.danger))
                    if turn.durationSeconds > 0 {
                        Text(String(format: "%.1fs", turn.durationSeconds))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(AgyTheme.textMuted)
                    }
                    if let total = turn.usage?.total_tokens {
                        Text("\(total) tok")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(AgyTheme.textMuted)
                    }
                }
            }
        }
    }
}

struct ToolStepCard: View {
    let step: AgentToolStep
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if step.state == "ACTIVE" {
                        ProgressView().scaleEffect(0.7).tint(AgyTheme.warning)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(AgyTheme.success)
                    }
                    Text(step.toolName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(AgyTheme.accentCyan)
                    Spacer()
                    if let d = step.durationSeconds {
                        Text(String(format: "%.2fs", d))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(AgyTheme.textMuted)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(AgyTheme.textMuted)
                }
            }

            if expanded {
                if !step.parametersJson.isEmpty {
                    Text(step.parametersJson)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(AgyTheme.textSecondary)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AgyTheme.bgInput)
                        .cornerRadius(6)
                }
                if !step.output.isEmpty {
                    Text(String(step.output.prefix(1500)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(AgyTheme.textPrimary)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AgyTheme.bgInput)
                        .cornerRadius(6)
                }
            }
        }
        .padding(10)
        .background(AgyTheme.bgSidebar)
        .cornerRadius(9)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(AgyTheme.borderSubtle, lineWidth: 1))
    }
}

struct FileMentionPickerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    let workspacePath: String
    @Binding var selectedFiles: [String]
    @State private var query = ""
    @State private var results: [FsEntryItem] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Filter files in workspace...", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding()
                    .onChange(of: query) { _, _ in Task { await load() } }

                List(results) { item in
                    Button {
                        if !selectedFiles.contains(item.path) {
                            selectedFiles.append(item.path)
                        }
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc.text")
                                .foregroundColor(item.isDirectory ? AgyTheme.accentCyan : AgyTheme.textSecondary)
                            Text(item.displayName)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(AgyTheme.textPrimary)
                        }
                    }
                    .listRowBackground(AgyTheme.bgCard)
                }
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .background(AgyTheme.bgCanvas)
            .navigationTitle("@ Mention File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        hideKeyboard()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        hideKeyboard()
                    } label: {
                        Label("Ẩn bàn phím", systemImage: "keyboard.chevron.compact.down")
                    }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let token = appState.activeProfile?.token, !workspacePath.isEmpty else { return }
        if let items = try? await appState.client.searchFiles(root: workspacePath, query: query, token: token) {
            results = items
        }
    }
}
