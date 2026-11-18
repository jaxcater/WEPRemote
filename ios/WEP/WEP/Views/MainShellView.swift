import SwiftUI

struct MainShellView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                AgyTheme.bgCanvas.ignoresSafeArea()

                VStack(spacing: 0) {
                    topStudioBar
                    Divider().background(AgyTheme.borderSubtle)

                    Group {
                        switch appState.activeTab {
                        case .chat:
                            ChatCanvasView()
                        case .explorer:
                            FileExplorerView()
                        case .code:
                            CodeEditorView()
                        case .extensions:
                            ExtensionsView()
                        case .terminal:
                            TerminalView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    bottomSurfaceSwitcher
                }

                if appState.showSidebar {
                    Color.black.opacity(0.58)
                        .ignoresSafeArea()
                        .onTapGesture {
                            hideKeyboard()
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                appState.showSidebar = false
                            }
                        }

                    SidebarView()
                        .frame(width: 312)
                        .transition(.move(edge: .leading))
                        .zIndex(2)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if appState.activeTab != .code {
                        Spacer()
                        Button {
                            hideKeyboard()
                        } label: {
                            Label("Ẩn bàn phím", systemImage: "keyboard.chevron.compact.down")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                }
            }
        }
        .onChange(of: appState.activeTab) { _, _ in
            hideKeyboard()
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

    private var topStudioBar: some View {
        HStack(spacing: 8) {
            Button {
                hideKeyboard()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    appState.showSidebar.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(AgyTheme.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(AgyTheme.bgCard)
                    .cornerRadius(9)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(AgyTheme.borderSubtle, lineWidth: 1))
            }

            Button {
                appState.activeTab = .explorer
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: (appState.cursorLive?.isCursorRunning == true) ? "cursorarrow.rays" : "folder.fill")
                        .font(.system(size: 12))
                        .foregroundColor((appState.cursorLive?.isCursorRunning == true) ? AgyTheme.accentCodex : AgyTheme.accentCyan)
                    Text(workspaceShortName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AgyTheme.textPrimary)
                        .lineLimit(1)
                    if let branch = appState.gitStatus?.branch, !branch.isEmpty {
                        Text(branch)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(AgyTheme.accentIndigo)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(AgyTheme.accentIndigo.opacity(0.16))
                            .cornerRadius(5)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AgyTheme.bgCard)
                .cornerRadius(9)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(AgyTheme.borderSubtle, lineWidth: 1))
            }

            Spacer()

            if appState.cursorLive?.isCursorRunning == true {
                Button {
                    Task { await appState.syncWithActiveCursor() }
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(AgyTheme.accentCodex)
                            .frame(width: 6, height: 6)
                        Text("Cursor")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AgyTheme.accentCodex)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(AgyTheme.accentCodex.opacity(0.13))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgyTheme.accentCodex.opacity(0.35), lineWidth: 1))
                }
            }

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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AgyTheme.textSecondary)
                }
                .padding(.horizontal, 8)
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
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AgyTheme.textPrimary)
                        .frame(width: 34, height: 34)
                        .background(AgyTheme.bgCard)
                        .cornerRadius(9)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(AgyTheme.borderSubtle, lineWidth: 1))

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
            tabButton(.extensions, icon: "puzzlepiece.extension", label: "Extensions")
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
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
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
