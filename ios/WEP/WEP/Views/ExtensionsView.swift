import SwiftUI

struct ExtensionsView: View {
    @EnvironmentObject var appState: AppState

    @State private var searchQuery = ""
    @State private var installId = ""
    @State private var sourceFilter = "all"

    private var filteredExtensions: [ExtensionItem] {
        appState.extensions.filter { item in
            let matchesSource = sourceFilter == "all" || item.source == sourceFilter
            let matchesQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                item.name.localizedCaseInsensitiveContains(searchQuery) ||
                item.id.localizedCaseInsensitiveContains(searchQuery) ||
                item.publisher.localizedCaseInsensitiveContains(searchQuery)
            return matchesSource && matchesQuery
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header + Install Bar
            VStack(spacing: 10) {
                HStack {
                    Text("Extensions & Plugins")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(AgyTheme.textPrimary)
                    Spacer()
                    Button {
                        Task { await appState.updateAllExtensions() }
                    } label: {
                        Label("Update All", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AgyTheme.accentCyan)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(AgyTheme.bgElevated)
                            .cornerRadius(8)
                    }
                    .disabled(appState.isLoadingExtensions || !appState.isConnected)
                }

                HStack(spacing: 8) {
                    TextField("Install Cursor extension (publisher.name)...", text: $installId)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(AgyTheme.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(AgyTheme.bgInput)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AgyTheme.borderSubtle, lineWidth: 1))

                    Button("Install") {
                        let id = installId
                        installId = ""
                        Task { await appState.installExtension(id: id) }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AgyTheme.accentIndigo)
                    .cornerRadius(8)
                    .disabled(installId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isLoadingExtensions)
                }

                HStack(spacing: 8) {
                    TextField("Filter installed...", text: $searchQuery)
                        .font(.system(size: 12.5))
                        .foregroundColor(AgyTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AgyTheme.bgInput)
                        .cornerRadius(8)

                    Picker("Source", selection: $sourceFilter) {
                        Text("All").tag("all")
                        Text("Cursor").tag("cursor")
                        Text("AGY").tag("antigravity")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }

                if let msg = appState.extensionStatusMessage {
                    HStack {
                        Text(msg)
                            .font(.system(size: 11.5))
                            .foregroundColor(AgyTheme.accentCyan)
                        Spacer()
                    }
                }
            }
            .padding(12)
            .background(AgyTheme.bgSidebar)

            Divider().background(AgyTheme.borderSubtle)

            if appState.isLoadingExtensions && appState.extensions.isEmpty {
                Spacer()
                ProgressView("Loading Cursor & Antigravity extensions...")
                    .tint(AgyTheme.accentCyan)
                Spacer()
            } else {
                List {
                    ForEach(filteredExtensions) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(item.source == "antigravity" ? "AGY" : "CURSOR")
                                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(item.source == "antigravity" ? AgyTheme.accentIndigo : AgyTheme.accentCodex)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background((item.source == "antigravity" ? AgyTheme.accentIndigo : AgyTheme.accentCodex).opacity(0.16))
                                            .cornerRadius(4)

                                        Text(item.name)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(AgyTheme.textPrimary)
                                    }

                                    Text("\(item.id) • v\(item.version) • \(item.publisher)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(AgyTheme.textMuted)
                                }

                                Spacer()

                                if item.source == "antigravity" {
                                    Button {
                                        Task { await appState.togglePlugin(item) }
                                    } label: {
                                        Text(item.enabled ? "Enabled" : "Disabled")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(item.enabled ? AgyTheme.success : AgyTheme.textMuted)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(AgyTheme.bgElevated)
                                            .cornerRadius(6)
                                    }
                                }
                            }

                            if !item.description.isEmpty {
                                Text(item.description)
                                    .font(.system(size: 12))
                                    .foregroundColor(AgyTheme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(AgyTheme.bgCard)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await appState.uninstallExtension(item) }
                            } label: {
                                Label("Uninstall", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable {
                    await appState.refreshExtensions()
                }
            }
        }
        .background(AgyTheme.bgCanvas)
        .task {
            if appState.extensions.isEmpty {
                await appState.refreshExtensions()
            }
        }
    }
}
