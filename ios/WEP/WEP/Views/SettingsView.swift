import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("AI Engine, Model & Effort") {
                    Picker("Engine", selection: Binding(
                        get: { appState.selectedEngine },
                        set: { appState.selectEngine($0) }
                    )) {
                        ForEach(AgentEngine.allCases) { eng in
                            Text(eng.displayName).tag(eng)
                        }
                    }

                    Picker("Model", selection: Binding(
                        get: { appState.selectedModel },
                        set: { appState.selectModel($0) }
                    )) {
                        ForEach(appState.modelsForSelectedEngine) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }

                    Picker("Reasoning Effort", selection: $appState.selectedEffort) {
                        ForEach(appState.supportedEffortsForCurrentModel, id: \.self) { eff in
                            Text(ReasoningEffort(rawValue: eff)?.label ?? eff.capitalized).tag(eff)
                        }
                    }

                    Picker("Execution Mode", selection: $appState.selectedMode) {
                        ForEach(ExecutionMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    Toggle("Auto-approve remote tool calls", isOn: $appState.skipPermissions)
                }
                .listRowBackground(AgyTheme.bgCard)

                Section("Active Windows Host") {
                    LabeledContent("Host Name", value: appState.hostInfo?.deviceName ?? appState.activeProfile?.name ?? "None")
                    LabeledContent("Route", value: appState.connectionRoute)
                    LabeledContent("Antigravity CLI", value: (appState.hostInfo?.agyInstalled ?? false) ? "Ready" : "Unavailable")
                    LabeledContent("Codex CLI", value: (appState.hostInfo?.codexInstalled ?? false) ? "Ready" : "Unavailable")
                    LabeledContent("Cursor Live", value: (appState.cursorLive?.isCursorRunning ?? false) ? "Running (\(appState.cursorLive?.processCount ?? 0))" : "Idle")
                    if let tunnel = appState.hostInfo?.tunnelUrl ?? appState.activeProfile?.tunnelUrl, !tunnel.isEmpty {
                        LabeledContent("Tunnel", value: tunnel)
                    }
                    if let lan = appState.hostInfo?.lanUrl ?? appState.activeProfile?.lanUrl, !lan.isEmpty {
                        LabeledContent("LAN", value: lan)
                    }
                }
                .listRowBackground(AgyTheme.bgCard)

                Section {
                    Button("Refresh Host Info & Models") {
                        Task { await appState.refreshHostData() }
                    }
                    Button("Pair / Switch Host") {
                        dismiss()
                        appState.showPairingSheet = true
                    }
                }
                .listRowBackground(AgyTheme.bgCard)
            }
            .scrollContentBackground(.hidden)
            .background(AgyTheme.bgCanvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
