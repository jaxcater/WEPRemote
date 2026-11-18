import AVFoundation
import SwiftUI

struct PairingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var name = "Home PC"
    @State private var tunnelUrl = ""
    @State private var lanUrl = ""
    @State private var token = ""
    @State private var showQrScanner = false
    @State private var statusText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Quick Pair via QR Code") {
                    Button {
                        showQrScanner = true
                    } label: {
                        Label("Scan QR Code on WEP Host", systemImage: "qrcode.viewfinder")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AgyTheme.accentCyan)
                    }

                    Button {
                        if let paste = UIPasteboard.general.string {
                            parsePairingJSON(paste)
                        }
                    } label: {
                        Label("Paste Pairing JSON from Clipboard", systemImage: "doc.on.clipboard")
                            .foregroundColor(AgyTheme.textPrimary)
                    }
                }
                .listRowBackground(AgyTheme.bgCard)

                Section("Host Credentials") {
                    TextField("PC Name", text: $name)
                    TextField("Cloudflare Tunnel URL (https://...)", text: $tunnelUrl)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("LAN URL (http://192.168.x.x:8420)", text: $lanUrl)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Access Token (wep_...)", text: $token)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .listRowBackground(AgyTheme.bgCard)

                if let statusText {
                    Section {
                        Text(statusText)
                            .font(.system(size: 12.5))
                            .foregroundColor(AgyTheme.warning)
                    }
                    .listRowBackground(AgyTheme.bgCard)
                }

                Section {
                    Button {
                        Task { await connectNow() }
                    } label: {
                        HStack {
                            Spacer()
                            if appState.isConnecting {
                                ProgressView().tint(.white)
                            } else {
                                Text("Connect to Home PC")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .listRowBackground(AgyTheme.accentIndigo)
                    .foregroundColor(.white)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              (tunnelUrl.isEmpty && lanUrl.isEmpty))
                }

                if !appState.profiles.isEmpty {
                    Section("Saved PCs") {
                        ForEach(appState.profiles) { profile in
                            Button {
                                Task {
                                    await appState.connect(to: profile)
                                    if appState.isConnected { dismiss() }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(AgyTheme.textPrimary)
                                        Text(profile.tunnelUrl ?? profile.lanUrl ?? "")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(AgyTheme.textMuted)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if appState.activeProfile?.id == profile.id && appState.isConnected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(AgyTheme.success)
                                    }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    appState.removeProfile(profile)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listRowBackground(AgyTheme.bgCard)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(AgyTheme.bgCanvas)
            .navigationTitle("Pair Windows Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        hideKeyboard()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        hideKeyboard()
                    } label: {
                        Label("Ẩn bàn phím", systemImage: "keyboard.chevron.compact.down")
                    }
                }
            }
            .sheet(isPresented: $showQrScanner) {
                QRScannerSheet { scanned in
                    showQrScanner = false
                    parsePairingJSON(scanned)
                }
            }
        }
    }

    private func parsePairingJSON(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(HostProfile.self, from: data) else {
            statusText = "Clipboard/QR did not contain valid WEP pairing JSON."
            return
        }
        name = payload.name
        tunnelUrl = payload.tunnelUrl ?? ""
        lanUrl = payload.lanUrl ?? ""
        token = payload.token
        statusText = "Pairing info loaded. Connecting..."
        Task { await connectNow() }
    }

    private func connectNow() async {
        let profile = HostProfile(
            name: name.isEmpty ? "Home PC" : name,
            tunnelUrl: tunnelUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            lanUrl: lanUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            version: "1.0.0"
        )
        await appState.addOrUpdateAndConnect(profile: profile)
        if appState.isConnected {
            dismiss()
        } else {
            statusText = appState.connectionError ?? "Connection failed."
        }
    }
}

struct QRScannerSheet: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onCodeScanned = onCodeScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var didEmit = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let session = AVCaptureSession()
        guard let videoDevice = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(input) else {
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.layer.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        self.captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !didEmit,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let str = obj.stringValue else {
            return
        }
        didEmit = true
        captureSession?.stopRunning()
        onCodeScanned?(str)
    }
}
