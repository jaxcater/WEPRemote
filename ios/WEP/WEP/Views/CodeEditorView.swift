import SwiftUI

struct CodeEditorView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var isFocused: Bool

    private let quickSymbols = ["    ", "{", "}", "(", ")", "[", "]", "=", ";", "\"", "'", "/", "\\", "_"]

    var body: some View {
        VStack(spacing: 0) {
            if appState.openFilePath.isEmpty {
                noFileOpenState
            } else {
                editorHeader
                Divider().background(AgyTheme.borderSubtle)

                if let msg = appState.editorMessage {
                    HStack {
                        Text(msg)
                            .font(.system(size: 11.5))
                            .foregroundColor(AgyTheme.accentCyan)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AgyTheme.accentCyan.opacity(0.1))
                }

                // Direct Monospace Code Editor
                TextEditor(text: $appState.editorContent)
                    .focused($isFocused)
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundColor(AgyTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(AgyTheme.bgInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 6)

                if isFocused {
                    codingAccessoryBar
                }
            }
        }
        .background(AgyTheme.bgCanvas)
    }

    private var noFileOpenState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 38))
                .foregroundStyle(AgyTheme.brandGradient)
            Text("Direct Remote Code Editor")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AgyTheme.textPrimary)
            Text("Open any file from the Folders tab to edit code directly on your home Windows PC.")
                .font(.system(size: 13))
                .foregroundColor(AgyTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Browse Folders") {
                appState.activeTab = .explorer
            }
            .buttonStyle(.borderedProminent)
            .tint(AgyTheme.accentIndigo)
            Spacer()
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(appState.openFileName)
                        .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(AgyTheme.textPrimary)
                        .lineLimit(1)
                    if appState.isEditorDirty {
                        Circle()
                            .fill(AgyTheme.warning)
                            .frame(width: 7, height: 7)
                    }
                }
                Text(appState.openFilePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(AgyTheme.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Task { await appState.openInCursor(path: appState.openFilePath) }
            } label: {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 13))
                    .foregroundColor(AgyTheme.accentCodex)
                    .frame(width: 30, height: 30)
                    .background(AgyTheme.bgElevated)
                    .cornerRadius(7)
            }

            Button {
                Task { await appState.openFileInEditor(path: appState.openFilePath) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundColor(AgyTheme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(AgyTheme.bgElevated)
                    .cornerRadius(7)
            }

            Button {
                isFocused = false
                appState.activeTab = .chat
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundColor(AgyTheme.accentCyan)
                    .frame(width: 30, height: 30)
                    .background(AgyTheme.bgElevated)
                    .cornerRadius(7)
            }

            Button {
                Task { await appState.saveCurrentFile() }
            } label: {
                HStack(spacing: 4) {
                    if appState.isSavingFile {
                        ProgressView().scaleEffect(0.7).tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Text("Save")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(appState.isEditorDirty ? AgyTheme.accentIndigo : AgyTheme.bgElevated)
                .cornerRadius(7)
            }
            .disabled(!appState.isEditorDirty || appState.isSavingFile)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AgyTheme.bgSidebar)
    }

    private var codingAccessoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button("Done") {
                    isFocused = false
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AgyTheme.accentCyan)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AgyTheme.bgElevated)
                .cornerRadius(6)

                ForEach(quickSymbols, id: \.self) { sym in
                    Button {
                        appState.editorContent += sym
                    } label: {
                        Text(sym == "    " ? "Tab" : sym)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(AgyTheme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(AgyTheme.bgCard)
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AgyTheme.borderSubtle, lineWidth: 1))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(AgyTheme.bgSidebar)
        .overlay(Rectangle().frame(height: 1).foregroundColor(AgyTheme.borderSubtle), alignment: .top)
    }
}
