import SwiftUI

struct MainShellView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack(alignment: .leading) {
            AgyTheme.bgCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                topAntigravityBar
                Divider().background(AgyTheme.borderSubtle)

                Group {
                    switch appState.activeTab {
                    case .chat:
                        ChatCanvasView()
                    case .explorer:
                        FileExplorerView()
                    case .code:
                        CodeEditorView()
                    case .terminal:
                        TerminalView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomSurfaceSwitcher
            }

            if appState.showSidebar {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            appState.showSidebar = false
                        }
                    }

                SidebarView()
                    .frame(width: 300)
                    .transition(.move(edge: .leading))
                    .zIndex(2)
            }
        }
        .sheet(isPresented: $appState.showAuxiliaryPane) {
            AuxiliaryPaneView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $appState.showPairingSheet) {
            PairingView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $appState.showSettingsSheet) {
            SettingsView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
    }

    private var topAntigravityBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    appState.showSidebar.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(AgyTheme.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(AgyTheme.bgCard)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AgyTheme.borderSubtle, lineWidth: 1))
            }

            Button {
                appState.activeTab = .explorer
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundColor(AgyTheme.accentCyan)
                    Text(workspaceShortName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AgyTheme.textPrimary)
                        .lineLimit(1)
                    if let branch = appState.gitStatus?.branch, !branch.isEmpty {
                        Text(branch)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(AgyTheme.accentIndigo)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AgyTheme.accentIndigo.opacity(0.16))
                            .cornerRadius(5)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AgyTheme.bgCard)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AgyTheme.borderSubtle, lineWidth: 1))
            }

            Spacer()

            Button {
                if let profile = appState.activeProfile {
                    Task { await appState.connect(to: profile) }
                } else {
                    appState.showPairingSheet = true
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(appState.isConnected ? AgyTheme.success : AgyTheme.danger)
                        .frame(width: 7, height: 7)
                    Text(appState.isConnected ? appState.connectionRoute : "Offline")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(AgyTheme.textSecondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(AgyTheme.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgyTheme.borderSubtle, lineWidth: 1))
            }

            Button {
                appState.showAuxiliaryPane = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "rectangle.righthalf.inset.filled")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(AgyTheme.textPrimary)
                        .frame(width: 34, height: 34)
                        .background(AgyTheme.bgCard)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AgyTheme.borderSubtle, lineWidth: 1))

                    if let count = appState.gitStatus?.changedFiles.count, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(AgyTheme.accentIndigo)
                            .clipShape(Capsule())
                            .offset(x: 4, y: -4)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AgyTheme.bgSidebar)
    }

    private var bottomSurfaceSwitcher: some View {
        HStack(spacing: 0) {
            tabButton(.chat, icon: "sparkles", label: "Agent")
            tabButton(.explorer, icon: "folder", label: "Folders")
            tabButton(.code, icon: "chevron.left.forwardslash.chevron.right", label: appState.isEditorDirty ? "Code *" : "Code")
            tabButton(.terminal, icon: "terminal", label: "Terminal")
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(AgyTheme.bgSidebar)
        .overlay(Rectangle().frame(height: 1).foregroundColor(AgyTheme.borderSubtle), alignment: .top)
    }

    private func tabButton(_ tab: MainSurfaceTab, icon: String, label: String) -> some View {
        let selected = appState.activeTab == tab
        return Button {
            appState.activeTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: selected ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
            }
            .foregroundColor(selected ? AgyTheme.accentCyan : AgyTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }

    private var workspaceShortName: String {
        if appState.activeWorkspace.isEmpty { return "Select Folder" }
        let normalized = appState.activeWorkspace.replacingOccurrences(of: "\\", with: "/")
        let last = (normalized as NSString).lastPathComponent
        return last.isEmpty ? appState.activeWorkspace : last
    }
}
