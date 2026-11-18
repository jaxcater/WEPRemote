import SwiftUI

struct ChatCanvasView: View {
    @EnvironmentObject var appState: AppState

    @State private var promptText = ""
    @State private var attachedFiles: [String] = []
    @State private var showFileMentionSheet = false
    @State private var showSlashMenu = false

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
                                TurnView(turn: turn)
                                    .id(turn.id)
                            }
                        }
                        .padding(14)
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
                emptyAntigravityCanvas
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

    private var emptyAntigravityCanvas: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 28)

                ZStack {
                    Circle()
                        .fill(AgyTheme.brandGradient.opacity(0.18))
                        .frame(width: 72, height: 72)
                    Image(systemName: "sparkles")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(AgyTheme.brandGradient)
                }

                VStack(spacing: 6) {
                    Text("Antigravity Remote")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(AgyTheme.textPrimary)
                    Text(appState.activeWorkspace.isEmpty
                         ? "Pair your Windows PC or open a folder to start coding"
                         : appState.activeWorkspace)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(AgyTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    starterCard(icon: "folder.badge.gearshape", title: "Open Folder", subtitle: "Browse Windows drives") {
                        appState.activeTab = .explorer
                    }
                    starterCard(icon: "doc.text.magnifyingglass", title: "Explain Repo", subtitle: "Map architecture") {
                        promptText = "Analyze this workspace folder and explain its architecture, entry points, and build setup."
                    }
                    starterCard(icon: "wrench.and.screwdriver", title: "Fix & Build", subtitle: "Run build & resolve errors") {
                        promptText = "Check the project build and tests, then fix any issues."
                    }
                    starterCard(icon: "terminal", title: "Remote Shell", subtitle: "Run PowerShell commands") {
                        appState.activeTab = .terminal
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .padding(.bottom, 24)
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
        VStack(spacing: 8) {
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

            VStack(spacing: 8) {
                TextField("Ask Antigravity to edit, run, or build...", text: $promptText, axis: .vertical)
                    .lineLimit(1...6)
                    .font(.system(size: 14.5))
                    .foregroundColor(AgyTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                HStack(spacing: 8) {
                    Button {
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

                    // Model picker pill
                    Menu {
                        ForEach(appState.models) { m in
                            Button {
                                appState.selectedModel = m.id
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
                        HStack(spacing: 4) {
                            Image(systemName: "cpu")
                                .font(.system(size: 10))
                            Text(shortModelName(appState.selectedModel))
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(AgyTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
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
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(AgyTheme.accentIndigo.opacity(0.14))
                        .cornerRadius(7)
                    }

                    Spacer()

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
                    } else {
                        Button {
                            let toSend = promptText
                            let files = attachedFiles
                            promptText = ""
                            attachedFiles = []
                            showSlashMenu = false
                            Task { await appState.sendPrompt(toSend, attachedFiles: files) }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .background(
                                    promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? AnyShapeStyle(AgyTheme.bgElevated)
                                        : AnyShapeStyle(AgyTheme.brandGradient)
                                )
                                .clipShape(Circle())
                        }
                        .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !appState.isConnected)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .background(AgyTheme.bgCard)
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AgyTheme.borderSubtle, lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(AgyTheme.bgCanvas)
    }

    private func shortModelName(_ id: String) -> String {
        appState.models.first(where: { $0.id == id })?.displayName
            .replacingOccurrences(of: " (High)", with: "")
            .replacingOccurrences(of: " (Medium)", with: "") ?? id
    }
}

struct TurnView: View {
    let turn: SessionTurn
    @State private var showThinking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // User Prompt Bubble
            HStack {
                Spacer(minLength: 36)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(turn.prompt)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .background(AgyTheme.accentIndigo.opacity(0.32))
                        .cornerRadius(13)
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(AgyTheme.accentIndigo.opacity(0.5), lineWidth: 1))
                }
            }

            // Thinking Accordion
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
                        Text("Thought Process")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AgyTheme.textSecondary)
                    }
                }
                .padding(10)
                .background(AgyTheme.bgCard)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgyTheme.borderSubtle, lineWidth: 1))
            }

            // Tool Execution Steps
            ForEach(turn.toolSteps) { step in
                ToolStepCard(step: step)
            }

            // Agent Response
            if !turn.responseText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                            .foregroundStyle(AgyTheme.brandGradient)
                        Text("Antigravity")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AgyTheme.textSecondary)
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
                        .tint(AgyTheme.accentCyan)
                    Text("Antigravity is working on your PC...")
                        .font(.system(size: 12.5))
                        .foregroundColor(AgyTheme.textSecondary)
                }
                .padding(10)
            }

            // Footer stats
            if turn.status != "running" {
                HStack(spacing: 10) {
                    Label(turn.status.uppercased(), systemImage: turn.status == "success" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(turn.status == "success" ? AgyTheme.success : AgyTheme.danger)
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
            }
            .background(AgyTheme.bgCanvas)
            .navigationTitle("@ Mention File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
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
