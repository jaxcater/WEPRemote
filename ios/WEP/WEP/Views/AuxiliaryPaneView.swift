import SwiftUI

struct AuxiliaryPaneView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var selectedSection = 0
    @State private var selectedDiffFile: String?
    @State private var diffText: String = ""
    @State private var isLoadingDiff = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Auxiliary Pane", selection: $selectedSection) {
                    Text("Files Changed").tag(0)
                    Text("Tool Timeline").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedSection == 0 {
                    filesChangedView
                } else {
                    toolTimelineView
                }
            }
            .background(AgyTheme.bgCanvas)
            .navigationTitle("Auxiliary Pane")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await appState.refreshGitStatus()
            }
        }
    }

    private var filesChangedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let git = appState.gitStatus, git.isGitRepo {
                if git.changedFiles.isEmpty {
                    VStack(spacing: 10) {
                        Spacer()
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 30))
                            .foregroundColor(AgyTheme.success)
                        Text("Working tree clean on \(git.branch ?? "HEAD")")
                            .font(.system(size: 13))
                            .foregroundColor(AgyTheme.textSecondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(git.changedFiles) { file in
                        Button {
                            selectedDiffFile = file.path
                            Task { await loadDiff(file: file.path) }
                        } label: {
                            HStack {
                                Text(file.status)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(AgyTheme.warning)
                                    .frame(width: 26)
                                Text(file.path)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundColor(AgyTheme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                        .listRowBackground(AgyTheme.bgCard)
                    }
                    .frame(maxHeight: 230)
                    .scrollContentBackground(.hidden)

                    Divider().background(AgyTheme.borderSubtle)

                    ScrollView {
                        if isLoadingDiff {
                            ProgressView().padding()
                        } else if diffText.isEmpty {
                            Text("Tap a changed file above to inspect its git diff.")
                                .font(.system(size: 12))
                                .foregroundColor(AgyTheme.textMuted)
                                .padding()
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(diffText.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundColor(diffLineColor(line))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(10)
                        }
                    }
                    .background(AgyTheme.bgInput)
                }
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Text("Not a git repository")
                        .foregroundColor(AgyTheme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var toolTimelineView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                let steps = appState.activeSession?.turns.flatMap(\.toolSteps) ?? []
                if steps.isEmpty {
                    Text("No tool calls executed in this conversation yet.")
                        .font(.system(size: 13))
                        .foregroundColor(AgyTheme.textMuted)
                        .padding(.top, 40)
                } else {
                    ForEach(steps) { step in
                        ToolStepCard(step: step)
                    }
                }
            }
            .padding()
        }
    }

    private func loadDiff(file: String) async {
        guard let token = appState.activeProfile?.token else { return }
        isLoadingDiff = true
        diffText = (try? await appState.client.gitDiff(cwd: appState.activeWorkspace, file: file, token: token)) ?? ""
        isLoadingDiff = false
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return AgyTheme.success }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return AgyTheme.danger }
        if line.hasPrefix("@@") { return AgyTheme.accentCyan }
        return AgyTheme.textSecondary
    }
}
