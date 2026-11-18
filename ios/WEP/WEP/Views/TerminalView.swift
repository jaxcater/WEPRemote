import SwiftUI

struct TerminalView: View {
    @EnvironmentObject var appState: AppState
    @State private var commandInput = ""

    private let quickCommands = ["git status", "git log -n 5 --oneline", "ls", "dotnet --version", "node -v"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundColor(AgyTheme.accentCyan)
                Text(appState.activeWorkspace.isEmpty ? "C:\\" : appState.activeWorkspace)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(AgyTheme.textSecondary)
                    .lineLimit(1)
                Spacer()
                if !appState.terminalLogs.isEmpty {
                    Button("Clear") {
                        appState.terminalLogs.removeAll()
                    }
                    .font(.system(size: 12))
                    .foregroundColor(AgyTheme.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AgyTheme.bgSidebar)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(quickCommands, id: \.self) { cmd in
                        Button(cmd) {
                            Task { await appState.runTerminalCommand(cmd) }
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(AgyTheme.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(AgyTheme.bgCard)
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AgyTheme.borderSubtle, lineWidth: 1))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(AgyTheme.bgCanvas)

            Divider().background(AgyTheme.borderSubtle)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if appState.terminalLogs.isEmpty {
                            Text("PowerShell output from your home Windows PC will appear here.")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundColor(AgyTheme.textMuted)
                                .padding(.top, 24)
                        } else {
                            ForEach(appState.terminalLogs) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("$ \(entry.command)")
                                            .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(AgyTheme.accentCyan)
                                        Spacer()
                                        Text("exit \(entry.exitCode)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(entry.exitCode == 0 ? AgyTheme.success : AgyTheme.danger)
                                    }

                                    if !entry.output.isEmpty {
                                        Text(entry.output)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(AgyTheme.textPrimary)
                                            .textSelection(.enabled)
                                    }

                                    if !entry.stderr.isEmpty {
                                        Text(entry.stderr)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(AgyTheme.danger)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(10)
                                .background(AgyTheme.bgCard)
                                .cornerRadius(8)
                                .id(entry.id)
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: appState.terminalLogs.count) { _, _ in
                    if let lastId = appState.terminalLogs.last?.id {
                        withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                    }
                }
            }
            .background(AgyTheme.bgInput)

            HStack(spacing: 8) {
                Text("PS>")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(AgyTheme.accentIndigo)
                TextField("Enter PowerShell command...", text: $commandInput)
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundColor(AgyTheme.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.send)
                    .onSubmit { runCurrent() }

                if appState.isRunningCommand {
                    ProgressView().tint(AgyTheme.accentCyan)
                } else {
                    Button {
                        runCurrent()
                    } label: {
                        Image(systemName: "return")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(AgyTheme.accentIndigo)
                            .cornerRadius(8)
                    }
                    .disabled(commandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !appState.isConnected)
                }
            }
            .padding(10)
            .background(AgyTheme.bgSidebar)
            .overlay(Rectangle().frame(height: 1).foregroundColor(AgyTheme.borderSubtle), alignment: .top)
        }
    }

    private func runCurrent() {
        let cmd = commandInput
        commandInput = ""
        Task { await appState.runTerminalCommand(cmd) }
    }
}
