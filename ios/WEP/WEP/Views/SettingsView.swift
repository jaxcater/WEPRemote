import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Antigravity Agent Defaults") {
                    Picker("Model", selection: $appState.selectedModel) {
                        ForEach(appState.models) { model in
                            Text(model.displayName).tag(model.id)
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
