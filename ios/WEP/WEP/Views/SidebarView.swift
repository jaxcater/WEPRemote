import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Antigravity Brand Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(AgyTheme.brandGradient)
                        .frame(width: 30, height: 30)
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("WEP")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(AgyTheme.textPrimary)
                    Text(appState.activeProfile?.name ?? "Antigravity iOS")
                        .font(.system(size: 11))
                        .foregroundColor(AgyTheme.textSecondary)
                }
                Spacer()
                Button {
                    withAnimation { appState.showSidebar = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AgyTheme.textSecondary)
                }
            }
            .padding(16)

            // + New Conversation
            Button {
                appState.startNewConversation()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.message.fill")
                    Text("New Conversation")
                        .fontWeight(.semibold)
                    Spacer()
                }
                .font(.system(size: 13.5))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AgyTheme.accentIndigo)
                .cornerRadius(9)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Divider().background(AgyTheme.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Projects / Open Folder
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("PROJECTS & FOLDERS")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(AgyTheme.textMuted)
                            Spacer()
                            Button("Browse") {
                                appState.activeTab = .explorer
                                appState.showSidebar = false
                            }
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(AgyTheme.accentCyan)
                        }

                        ForEach(appState.pinnedWorkspaces, id: \.self) { path in
                            let isCurrent = path.caseInsensitiveCompare(appState.activeWorkspace) == .orderedSame
                            Button {
                                Task {
                                    await appState.openFolderAsWorkspace(path)
                                    appState.showSidebar = false
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isCurrent ? "folder.fill" : "folder")
                                        .font(.system(size: 13))
                                        .foregroundColor(isCurrent ? AgyTheme.accentCyan : AgyTheme.textSecondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(folderBaseName(path))
                                            .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                                            .foregroundColor(AgyTheme.textPrimary)
                                            .lineLimit(1)
                                        Text(path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(AgyTheme.textMuted)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(8)
                                .background(isCurrent ? AgyTheme.bgElevated : Color.clear)
                                .cornerRadius(8)
                            }
                        }
                    }

                    // Conversations
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CONVERSATIONS")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(AgyTheme.textMuted)

                        if appState.sessions.isEmpty {
                            Text("No remote conversations yet")
                                .font(.system(size: 12))
                                .foregroundColor(AgyTheme.textMuted)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(appState.sessions) { session in
                                let selected = session.id == appState.activeSessionId
                                Button {
                                    appState.selectSession(session)
                                } label: {
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(session.isRunning ? AgyTheme.warning : (selected ? AgyTheme.accentCyan : AgyTheme.textMuted.opacity(0.4)))
                                            .frame(width: 7, height: 7)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(session.title.isEmpty ? "Conversation" : session.title)
                                                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                                .foregroundColor(AgyTheme.textPrimary)
                                                .lineLimit(1)
                                            Text("\(folderBaseName(session.workspacePath)) • \(session.turns.count) turns")
                                                .font(.system(size: 10.5))
                                                .foregroundColor(AgyTheme.textMuted)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(8)
                                    .background(selected ? AgyTheme.bgElevated : Color.clear)
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }

            Divider().background(AgyTheme.borderSubtle)

            // Footer Actions (Pair PC & Settings)
            VStack(spacing: 6) {
                Button {
                    appState.showSidebar = false
                    appState.showPairingSheet = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "qrcode.viewfinder")
                            .foregroundColor(AgyTheme.accentCyan)
                        Text("Pair / Switch Windows PC")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AgyTheme.textPrimary)
                        Spacer()
                    }
                    .padding(10)
                    .background(AgyTheme.bgCard)
                    .cornerRadius(8)
                }

                Button {
                    appState.showSidebar = false
                    appState.showSettingsSheet = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape")
                            .foregroundColor(AgyTheme.textSecondary)
                        Text("Antigravity Settings")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AgyTheme.textPrimary)
                        Spacer()
                    }
                    .padding(10)
                    .background(AgyTheme.bgCard)
                    .cornerRadius(8)
                }
            }
            .padding(12)
        }
        .background(AgyTheme.bgSidebar)
        .overlay(Rectangle().frame(width: 1).foregroundColor(AgyTheme.borderSubtle), alignment: .trailing)
    }

    private func folderBaseName(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let last = (normalized as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}
