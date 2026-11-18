import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Studio Brand Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(AgyTheme.brandGradient)
                        .frame(width: 32, height: 32)
                    Text("W")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("WEP Studio")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(AgyTheme.textPrimary)
                    Text(appState.activeProfile?.name ?? "Antigravity • Codex • Cursor")
                        .font(.system(size: 10.5))
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
                    Text(appState.selectedEngine.shortBadge)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(5)
                }
                .font(.system(size: 13.5))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(appState.selectedEngine == .codex ? AnyShapeStyle(AgyTheme.codexGradient) : AnyShapeStyle(AgyTheme.brandGradient))
                .cornerRadius(10)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Divider().background(AgyTheme.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Live Cursor Window Section
                    if let cursor = appState.cursorLive {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(cursor.isCursorRunning ? AgyTheme.accentCodex : AgyTheme.textMuted)
                                        .frame(width: 7, height: 7)
                                    Text("LIVE CURSOR SESSION")
                                        .font(.system(size: 10.5, weight: .bold))
                                        .foregroundColor(cursor.isCursorRunning ? AgyTheme.accentCodex : AgyTheme.textMuted)
                                }
                                Spacer()
                                Button("Sync") {
                                    Task {
                                        await appState.syncWithActiveCursor()
                                        appState.showSidebar = false
                                    }
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(AgyTheme.accentCyan)
                            }

                            if let activeWs = cursor.activeWorkspace, !activeWs.isEmpty {
                                Button {
                                    Task {
                                        await appState.openFolderAsWorkspace(activeWs)
                                        appState.showSidebar = false
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "cursorarrow.click.2")
                                            .foregroundColor(AgyTheme.accentCodex)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(folderBaseName(activeWs))
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundColor(AgyTheme.textPrimary)
                                            Text(cursor.activeWindowTitles.first ?? activeWs)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(AgyTheme.textSecondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(9)
                                    .background(AgyTheme.accentCodex.opacity(0.11))
                                    .cornerRadius(8)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AgyTheme.accentCodex.opacity(0.35), lineWidth: 1))
                                }
                            }
                        }
                    }

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

                    // WEP Conversations
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CONVERSATIONS")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(AgyTheme.textMuted)

                        if appState.sessions.isEmpty {
                            Text("No remote conversations yet")
                                .font(.system(size: 12))
                                .foregroundColor(AgyTheme.textMuted)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(appState.sessions) { session in
                                let selected = session.id == appState.activeSessionId
                                let eng = AgentEngine(rawValue: session.engine ?? "antigravity") ?? .antigravity
                                Button {
                                    appState.selectSession(session)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(eng.shortBadge)
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundColor(eng == .codex ? AgyTheme.accentCodex : AgyTheme.accentCyan)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background((eng == .codex ? AgyTheme.accentCodex : AgyTheme.accentIndigo).opacity(0.16))
                                            .cornerRadius(4)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(session.title.isEmpty ? "Conversation" : session.title)
                                                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                                .foregroundColor(AgyTheme.textPrimary)
                                                .lineLimit(1)
                                            Text("\(folderBaseName(session.workspacePath)) • \(session.effort ?? "high")")
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

                    // Cursor Codex Threads (~/.codex)
                    if !appState.codexThreads.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("CURSOR CODEX THREADS")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(AgyTheme.textMuted)

                            ForEach(appState.codexThreads.prefix(8)) { thread in
                                Button {
                                    Task {
                                        await appState.resumeCodexThread(thread)
                                        appState.showSidebar = false
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 11))
                                            .foregroundColor(AgyTheme.accentCodex)
                                        Text(thread.title)
                                            .font(.system(size: 12.5))
                                            .foregroundColor(AgyTheme.textSecondary)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(AgyTheme.bgCard)
                                    .cornerRadius(7)
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }

            Divider().background(AgyTheme.borderSubtle)

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
                        Text("Engines & Settings")
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
