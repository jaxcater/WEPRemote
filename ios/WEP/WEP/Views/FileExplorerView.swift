import SwiftUI

struct FileExplorerView: View {
    @EnvironmentObject var appState: AppState

    @State private var currentPath: String = ""
    @State private var parentPath: String?
    @State private var entries: [FsEntryItem] = []
    @State private var drives: [FsDriveItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var showCreateSheet = false
    @State private var newItemName = ""
    @State private var newItemIsFolder = false

    var body: some View {
        VStack(spacing: 0) {
            // Path & Open Folder Header
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if let parent = parentPath {
                        Button {
                            Task { await loadDirectory(parent) }
                        } label: {
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AgyTheme.textPrimary)
                                .frame(width: 30, height: 30)
                                .background(AgyTheme.bgElevated)
                                .cornerRadius(7)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(currentPath.isEmpty ? "Drives & Workspaces" : currentPath)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(AgyTheme.textSecondary)
                    }

                    Spacer()

                    Button {
                        newItemIsFolder = false
                        newItemName = ""
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AgyTheme.accentCyan)
                            .frame(width: 30, height: 30)
                            .background(AgyTheme.bgElevated)
                            .cornerRadius(7)
                    }
                    .disabled(currentPath.isEmpty)
                }

                if !currentPath.isEmpty {
                    let isWorkspace = currentPath.caseInsensitiveCompare(appState.activeWorkspace) == .orderedSame
                    Button {
                        Task {
                            await appState.openFolderAsWorkspace(currentPath)
                            appState.activeTab = .chat
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isWorkspace ? "checkmark.circle.fill" : "folder.badge.plus")
                            Text(isWorkspace ? "Active Antigravity Workspace (Tap to Chat)" : "Open This Folder in Antigravity")
                                .font(.system(size: 12.5, weight: .semibold))
                            Spacer()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(isWorkspace ? AgyTheme.success.opacity(0.85) : AgyTheme.accentIndigo)
                        .cornerRadius(8)
                    }
                }
            }
            .padding(12)
            .background(AgyTheme.bgSidebar)

            Divider().background(AgyTheme.borderSubtle)

            // Drives strip
            if !drives.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(drives) { drive in
                            Button {
                                Task { await loadDirectory(drive.path) }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "internaldrive")
                                        .font(.system(size: 11))
                                    Text(drive.name)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                }
                                .foregroundColor(AgyTheme.textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(AgyTheme.bgCard)
                                .cornerRadius(7)
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(AgyTheme.borderSubtle, lineWidth: 1))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(AgyTheme.bgCanvas)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(AgyTheme.danger)
                    .padding(10)
            }

            if isLoading {
                Spacer()
                ProgressView("Loading Windows directory...")
                    .tint(AgyTheme.accentCyan)
                Spacer()
            } else {
                List {
                    ForEach(entries) { entry in
                        Button {
                            if entry.isDirectory {
                                Task { await loadDirectory(entry.path) }
                            } else {
                                Task { await appState.openFileInEditor(path: entry.path) }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : fileIcon(entry.displayName))
                                    .font(.system(size: 16))
                                    .foregroundColor(entry.isDirectory ? AgyTheme.accentCyan : AgyTheme.textSecondary)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayName)
                                        .font(.system(size: 14, weight: entry.isDirectory ? .semibold : .regular))
                                        .foregroundColor(AgyTheme.textPrimary)
                                    if !entry.isDirectory, let size = entry.sizeBytes {
                                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                            .font(.system(size: 11))
                                            .foregroundColor(AgyTheme.textMuted)
                                    }
                                }
                                Spacer()
                                Image(systemName: entry.isDirectory ? "chevron.right" : "pencil")
                                    .font(.system(size: 12))
                                    .foregroundColor(AgyTheme.textMuted)
                            }
                            .padding(.vertical, 3)
                        }
                        .listRowBackground(AgyTheme.bgCard)
                        .swipeActions(edge: .trailing) {
                            if entry.isDirectory {
                                Button("Open") {
                                    Task {
                                        await appState.openFolderAsWorkspace(entry.path)
                                        appState.activeTab = .chat
                                    }
                                }
                                .tint(AgyTheme.accentIndigo)
                            }
                            Button(role: .destructive) {
                                Task { await deleteEntry(entry) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable {
                    await loadDirectory(currentPath.isEmpty ? appState.activeWorkspace : currentPath)
                }
            }
        }
        .background(AgyTheme.bgCanvas)
        .task {
            await initialLoad()
        }
        .alert("New Item in Folder", isPresented: $showCreateSheet) {
            TextField("File or folder name (e.g. main.swift or src)", text: $newItemName)
            Button("Create File") {
                Task { await createNewItem(isDir: false) }
            }
            Button("Create Folder") {
                Task { await createNewItem(isDir: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func initialLoad() async {
        guard let token = appState.activeProfile?.token else { return }
        if let d = try? await appState.client.getDrives(token: token) {
            drives = d
        }
        let target = currentPath.isEmpty
            ? (appState.activeWorkspace.isEmpty ? nil : appState.activeWorkspace)
            : currentPath
        await loadDirectory(target)
    }

    private func loadDirectory(_ path: String?) async {
        guard let token = appState.activeProfile?.token else { return }
        isLoading = true
        errorMessage = nil
        do {
            let res = try await appState.client.listDirectory(path: path, token: token)
            currentPath = res.currentPath
            parentPath = res.parentPath
            entries = res.entries
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func createNewItem(isDir: Bool) async {
        let name = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !currentPath.isEmpty, let token = appState.activeProfile?.token else { return }
        let sep = currentPath.hasSuffix("\\") ? "" : "\\"
        let fullPath = currentPath + sep + name
        do {
            try await appState.client.createItem(path: fullPath, isDirectory: isDir, token: token)
            await loadDirectory(currentPath)
            if !isDir {
                await appState.openFileInEditor(path: fullPath)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteEntry(_ entry: FsEntryItem) async {
        guard let token = appState.activeProfile?.token else { return }
        do {
            try await appState.client.deleteItem(path: entry.path, token: token)
            await loadDirectory(currentPath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fileIcon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "cs", "ts", "tsx", "js", "jsx", "py", "go", "rs": return "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "xml", "toml": return "curlybraces"
        case "md", "txt": return "doc.plaintext"
        default: return "doc.text"
        }
    }
}
