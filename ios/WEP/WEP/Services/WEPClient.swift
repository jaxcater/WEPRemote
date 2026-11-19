import Foundation
import Network

enum WEPError: LocalizedError {
    case notConfigured
    case invalidURL
    case httpError(Int, String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No host paired. Scan QR code or enter your WEP Host URL."
        case .invalidURL: return "Invalid host URL."
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .decodingError(let msg): return "Response error: \(msg)"
        }
    }
}

enum RoutePreference: String, CaseIterable, Codable, Identifiable {
    case auto = "auto"
    case preferTunnel = "tunnel"
    case preferLan = "lan"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto (Smart LAN / Tunnel)"
        case .preferTunnel: return "Force Tunnel (4G / Remote)"
        case .preferLan: return "Prefer LAN (Home Wi-Fi)"
        }
    }

    var shortLabel: String {
        switch self {
        case .auto: return "Auto"
        case .preferTunnel: return "Tunnel"
        case .preferLan: return "LAN"
        }
    }
}

final class WEPClient {
    private let apiSession: URLSession
    private let probeSession: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.wep.remote.pathmonitor")
    private var lastNetworkSignature: String = ""
    private(set) var isCellularOnly: Bool = false

    private var activeProfile: HostProfile?
    private var shouldMaintainConnection = false
    private var reconnectAttempt = 0

    var routePreference: RoutePreference = .auto
    private(set) var activeBaseURL: String = ""
    private(set) var activeRouteLabel: String = "Disconnected"

    var onWebSocketEvent: ((String, [String: Any]) -> Void)?
    var onConnectionStateChange: ((Bool, String) -> Void)?

    init() {
        // CRITICAL: waitsForConnectivity MUST be false so unreachable LAN IPs fail immediately
        // instead of hanging up to 120 seconds when on 4G/5G or an external Wi-Fi network.
        let apiCfg = URLSessionConfiguration.default
        apiCfg.timeoutIntervalForRequest = 14
        apiCfg.timeoutIntervalForResource = 90
        apiCfg.waitsForConnectivity = false
        apiCfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.apiSession = URLSession(configuration: apiCfg)

        let probeCfg = URLSessionConfiguration.ephemeral
        probeCfg.timeoutIntervalForRequest = 4
        probeCfg.timeoutIntervalForResource = 6
        probeCfg.waitsForConnectivity = false
        probeCfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.probeSession = URLSession(configuration: probeCfg)

        startNetworkPathMonitor()
    }

    deinit {
        pathMonitor?.cancel()
    }

    static func normalizeBaseURL(_ raw: String?, isTunnel: Bool) -> String {
        guard let raw else { return "" }
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty else { return "" }

        if !clean.lowercased().hasPrefix("http://") && !clean.lowercased().hasPrefix("https://") {
            if isTunnel || clean.lowercased().contains(".trycloudflare.com") {
                clean = "https://\(clean)"
            } else {
                clean = "http://\(clean)"
            }
        }
        return clean
    }

    private func startNetworkPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let usesWifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let usesCell = path.usesInterfaceType(.cellular)
            self.isCellularOnly = usesCell && !usesWifi

            let ifaces = path.availableInterfaces.map(\.name).joined(separator: ",")
            let sig = "\(path.status)-wifi:\(usesWifi)-cell:\(usesCell)-\(ifaces)"
            let previousSig = self.lastNetworkSignature
            self.lastNetworkSignature = sig

            guard !previousSig.isEmpty, previousSig != sig else { return }
            guard self.shouldMaintainConnection, self.activeProfile != nil else { return }

            // Network interface changed (e.g. Wi-Fi -> 4G/5G or vice versa): switch route immediately!
            self.triggerImmediateRouteSwitch()
        }
        monitor.start(queue: monitorQueue)
        self.pathMonitor = monitor
    }

    func triggerImmediateRouteSwitch() {
        guard shouldMaintainConnection, activeProfile != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownSocketOnly()
        reconnectAttempt = 0
        onConnectionStateChange?(false, "Switching...")
        scheduleReconnect(immediate: true)
    }

    func resolveAndConnect(profile: HostProfile) async throws {
        activeProfile = profile
        shouldMaintainConnection = true
        reconnectTask?.cancel()
        reconnectTask = nil

        let resolved = try await resolveReachableBaseURL(profile: profile)
        activeBaseURL = resolved.baseURL
        activeRouteLabel = resolved.routeLabel
        reconnectAttempt = 0
        connectWebSocket(baseURL: activeBaseURL, token: profile.token)
    }

    @discardableResult
    func resolveReachableBaseURL(profile: HostProfile) async throws -> (baseURL: String, routeLabel: String) {
        let lan = Self.normalizeBaseURL(profile.lanUrl, isTunnel: false)
        let tunnel = Self.normalizeBaseURL(profile.tunnelUrl, isTunnel: true)
        let token = profile.token

        // 1. If on 4G/5G cellular or user explicitly prefers Tunnel, try Tunnel first with zero LAN delay.
        if (routePreference == .preferTunnel || isCellularOnly), !tunnel.isEmpty {
            if await probeHealth(baseURL: tunnel, token: token, timeout: 6.5) {
                activeBaseURL = tunnel
                activeRouteLabel = "Tunnel"
                return (tunnel, "Tunnel")
            }
            if !lan.isEmpty, !isCellularOnly, await probeHealth(baseURL: lan, token: token, timeout: 1.0) {
                activeBaseURL = lan
                activeRouteLabel = "LAN"
                return (lan, "LAN")
            }
        }
        // 2. If user explicitly prefers LAN, try quick LAN probe then Tunnel.
        else if routePreference == .preferLan {
            if !lan.isEmpty, await probeHealth(baseURL: lan, token: token, timeout: 1.2) {
                activeBaseURL = lan
                activeRouteLabel = "LAN"
                return (lan, "LAN")
            }
            if !tunnel.isEmpty, await probeHealth(baseURL: tunnel, token: token, timeout: 6.5) {
                activeBaseURL = tunnel
                activeRouteLabel = "Tunnel"
                return (tunnel, "Tunnel")
            }
        }
        // 3. Smart Auto Mode: when BOTH LAN and Tunnel exist, race them IN PARALLEL so Tunnel
        // never waits for LAN to time out on external Wi-Fi networks!
        else if !lan.isEmpty && !tunnel.isEmpty {
            if let winner = await raceLanAndTunnel(lan: lan, tunnel: tunnel, token: token) {
                activeBaseURL = winner.baseURL
                activeRouteLabel = winner.routeLabel
                return winner
            }
        }
        // 4. Single-URL profile (only Tunnel or only LAN configured).
        else if !tunnel.isEmpty {
            if await probeHealth(baseURL: tunnel, token: token, timeout: 6.5) {
                activeBaseURL = tunnel
                activeRouteLabel = "Tunnel"
                return (tunnel, "Tunnel")
            }
        } else if !lan.isEmpty {
            if await probeHealth(baseURL: lan, token: token, timeout: 1.5) {
                activeBaseURL = lan
                activeRouteLabel = "LAN"
                return (lan, "LAN")
            }
        }

        let fallback = !tunnel.isEmpty ? tunnel : lan
        activeBaseURL = fallback
        activeRouteLabel = "Offline"
        onConnectionStateChange?(false, "Offline")
        throw WEPError.httpError(0, "Could not reach Windows host via Cloudflare Tunnel or LAN.")
    }

    private func raceLanAndTunnel(lan: String, tunnel: String, token: String) async -> (baseURL: String, routeLabel: String)? {
        await withTaskGroup(of: (String, String, Bool).self) { group in
            group.addTask {
                let ok = await self.probeHealth(baseURL: lan, token: token, timeout: 0.95)
                return (lan, "LAN", ok)
            }
            group.addTask {
                let ok = await self.probeHealth(baseURL: tunnel, token: token, timeout: 6.5)
                return (tunnel, "Tunnel", ok)
            }

            var tunnelWinner: (String, String)?
            for await (url, label, ok) in group {
                if ok {
                    if label == "LAN" {
                        group.cancelAll()
                        return (url, label)
                    } else {
                        // Tunnel succeeded first! Wait a tiny 120ms grace window in case home LAN is also reachable,
                        // otherwise immediately pick Tunnel and cancel LAN probe.
                        tunnelWinner = (url, label)
                        group.cancelAll()
                        return (url, label)
                    }
                }
            }
            return tunnelWinner
        }
    }

    func disconnectWebSocket() {
        shouldMaintainConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownSocketOnly()
        onConnectionStateChange?(false, "Disconnected")
    }

    private func teardownSocketOnly() {
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    private func probeHealth(baseURL: String, token: String, timeout: TimeInterval) async -> Bool {
        let clean = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(clean)/api/health") else { return false }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                do {
                    let (data, resp) = try await self.probeSession.data(for: req)
                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
                    let health = try JSONDecoder().decode(HealthResponse.self, from: data)
                    return health.ok && (health.authenticated ?? false)
                } catch {
                    return false
                }
            }
            group.addTask {
                let ns = UInt64(max(0.2, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                return false
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func connectWebSocket(baseURL: String, token: String) {
        teardownSocketOnly()

        let wsScheme = baseURL.hasPrefix("https://")
            ? "wss://" + baseURL.dropFirst("https://".count)
            : (baseURL.hasPrefix("http://") ? "ws://" + baseURL.dropFirst("http://".count) : "wss://\(baseURL)")

        guard let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let wsURL = URL(string: "\(wsScheme)/ws?token=\(encodedToken)") else {
            return
        }

        let task = apiSession.webSocketTask(with: wsURL)
        self.webSocketTask = task
        task.resume()
        onConnectionStateChange?(true, activeRouteLabel)

        pingTask = Task { [weak self, weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, let self, let task, self.webSocketTask === task else { break }
                let pingFailed = await self.sendPingWithTimeout(task: task, timeoutSeconds: 3.0)
                if pingFailed {
                    self.onConnectionStateChange?(false, "Switching...")
                    self.scheduleReconnect(immediate: true)
                    break
                }
            }
        }

        receiveTask = Task { [weak self, weak task] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task else { break }
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        self.handleRawWsMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleRawWsMessage(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        self.onConnectionStateChange?(false, "Reconnecting...")
                        self.scheduleReconnect(immediate: true)
                    }
                    break
                }
            }
        }
    }

    private func sendPingWithTimeout(task: URLSessionWebSocketTask, timeoutSeconds: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    task.sendPing { error in
                        cont.resume(returning: error != nil)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return true // Timed out -> failed
            }
            let failed = await group.next() ?? true
            group.cancelAll()
            return failed
        }
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard shouldMaintainConnection, let profile = activeProfile else { return }
        guard reconnectTask == nil else { return }

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.reconnectTask = nil }

            var isFirstLoop = immediate
            while !Task.isCancelled && self.shouldMaintainConnection {
                if !isFirstLoop {
                    let attempt = min(self.reconnectAttempt, 4)
                    self.reconnectAttempt += 1
                    let delaySeconds = UInt64(min(1 * (1 << attempt), 10))
                    try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                } else {
                    isFirstLoop = false
                }

                if Task.isCancelled || !self.shouldMaintainConnection { break }

                do {
                    let latestProfile = self.activeProfile ?? profile
                    let resolved = try await self.resolveReachableBaseURL(profile: latestProfile)
                    self.activeBaseURL = resolved.baseURL
                    self.activeRouteLabel = resolved.routeLabel
                    self.reconnectAttempt = 0
                    self.connectWebSocket(baseURL: resolved.baseURL, token: latestProfile.token)
                    return
                } catch {
                    // Continue retrying until connected or disconnected explicitly.
                }
            }
        }
    }

    func updateActiveProfile(_ profile: HostProfile) {
        self.activeProfile = profile
    }

    private func handleRawWsMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }
        let payload = json["payload"] as? [String: Any] ?? [:]
        onWebSocketEvent?(type, payload)
    }

    // MARK: - REST API

    func getInfo(token: String) async throws -> HostInfoResponse {
        try await request(path: "/api/info", token: token)
    }

    func getCursorLive(token: String) async throws -> CursorLiveState {
        try await request(path: "/api/cursor/live", token: token)
    }

    func openInCursor(path: String, line: Int? = nil, token: String) async throws -> GenericActionResponse {
        var body: [String: Any] = ["path": path]
        if let line { body["line"] = line }
        return try await request(path: "/api/cursor/open", method: "POST", jsonBody: body, token: token)
    }

    func listExtensions(token: String) async throws -> [ExtensionItem] {
        try await request(path: "/api/extensions", token: token)
    }

    func installExtension(id: String, source: String = "cursor", token: String) async throws -> GenericActionResponse {
        try await request(path: "/api/extensions/install", method: "POST", jsonBody: ["id": id, "source": source], token: token)
    }

    func uninstallExtension(id: String, source: String, token: String) async throws -> GenericActionResponse {
        try await request(path: "/api/extensions/uninstall", method: "POST", jsonBody: ["id": id, "source": source], token: token)
    }

    func updateExtensions(token: String) async throws -> GenericActionResponse {
        try await request(path: "/api/extensions/update", method: "POST", jsonBody: [:], token: token)
    }

    func togglePlugin(id: String, enable: Bool, token: String) async throws -> GenericActionResponse {
        try await request(path: "/api/extensions/plugin-toggle", method: "POST", jsonBody: ["id": id, "source": "antigravity", "enable": enable], token: token)
    }

    func listCodexThreads(token: String) async throws -> [CodexThreadSummary] {
        try await request(path: "/api/codex/threads", token: token)
    }

    func importCodexThread(threadId: String, title: String?, workspacePath: String?, model: String, effort: String, token: String) async throws -> SessionRecord {
        var body: [String: Any] = ["threadId": threadId, "model": model, "effort": effort]
        if let title { body["title"] = title }
        if let workspacePath { body["workspacePath"] = workspacePath }
        return try await request(path: "/api/codex/import", method: "POST", jsonBody: body, token: token)
    }

    func listSessions(token: String) async throws -> [SessionRecord] {
        try await request(path: "/api/sessions", token: token)
    }

    func createSession(engine: String, workspacePath: String, model: String, effort: String, mode: String, token: String) async throws -> SessionRecord {
        let body: [String: Any] = [
            "engine": engine,
            "workspacePath": workspacePath,
            "model": model,
            "effort": effort,
            "mode": mode
        ]
        return try await request(path: "/api/sessions", method: "POST", jsonBody: body, token: token)
    }

    func deleteSession(id: String, token: String) async throws {
        let _: [String: Bool] = try await request(path: "/api/sessions/\(id)", method: "DELETE", token: token)
    }

    func getDrives(token: String) async throws -> [FsDriveItem] {
        try await request(path: "/api/fs/drives", token: token)
    }

    func listDirectory(path: String?, hidden: Bool = false, token: String) async throws -> FsListResponse {
        var query = "?hidden=\(hidden)"
        if let path, let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query += "&path=\(encoded)"
        }
        return try await request(path: "/api/fs/list\(query)", token: token)
    }

    func searchFiles(root: String, query: String, token: String) async throws -> [FsEntryItem] {
        let er = root.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let eq = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return try await request(path: "/api/fs/search?root=\(er)&q=\(eq)", token: token)
    }

    func readFile(path: String, token: String) async throws -> FileContentResponse {
        let ep = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return try await request(path: "/api/fs/read?path=\(ep)", token: token)
    }

    func writeFile(path: String, content: String, token: String) async throws -> FileContentResponse {
        let body: [String: Any] = ["path": path, "content": content]
        return try await request(path: "/api/fs/write", method: "POST", jsonBody: body, token: token)
    }

    func createItem(path: String, isDirectory: Bool, token: String) async throws {
        let body: [String: Any] = ["path": path, "isDirectory": isDirectory]
        let _: [String: AnyCodable] = try await request(path: "/api/fs/create", method: "POST", jsonBody: body, token: token)
    }

    func deleteItem(path: String, token: String) async throws {
        let ep = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let _: [String: AnyCodable] = try await request(path: "/api/fs/item?path=\(ep)", method: "DELETE", token: token)
    }

    func pinWorkspace(path: String, token: String) async throws {
        let body: [String: Any] = ["path": path, "isDirectory": true]
        let _: [String: AnyCodable] = try await request(path: "/api/workspace/pin", method: "POST", jsonBody: body, token: token)
    }

    func gitStatus(cwd: String, token: String) async throws -> GitStatusResponse {
        let ec = cwd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return try await request(path: "/api/git/status?cwd=\(ec)", token: token)
    }

    func gitDiff(cwd: String, file: String?, token: String) async throws -> String {
        let ec = cwd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var url = "/api/git/diff?cwd=\(ec)"
        if let file, let ef = file.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            url += "&file=\(ef)"
        }
        let resp: GitDiffResponse = try await request(path: url, token: token)
        return resp.diff
    }

    func execTerminal(cwd: String, command: String, token: String) async throws -> TerminalExecResponse {
        let body: [String: Any] = ["cwd": cwd, "command": command, "timeoutSeconds": 90]
        return try await request(path: "/api/terminal/exec", method: "POST", jsonBody: body, token: token)
    }

    @discardableResult
    func startAgent(
        sessionId: String?,
        engine: String,
        workspacePath: String,
        prompt: String,
        model: String,
        effort: String,
        mode: String,
        skipPermissions: Bool,
        attachedFiles: [String],
        token: String
    ) async throws -> AgentStartResponse {
        var body: [String: Any] = [
            "engine": engine,
            "workspacePath": workspacePath,
            "prompt": prompt,
            "model": model,
            "effort": effort,
            "mode": mode,
            "skipPermissions": skipPermissions,
            "attachedFiles": attachedFiles
        ]
        if let sessionId { body["sessionId"] = sessionId }
        return try await request(path: "/api/agent/start", method: "POST", jsonBody: body, token: token)
    }

    func cancelAgent(sessionId: String, clearQueue: Bool = false, token: String) async throws {
        let es = sessionId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let _: [String: AnyCodable] = try await request(
            path: "/api/agent/cancel?sessionId=\(es)&clearQueue=\(clearQueue)",
            method: "POST",
            token: token
        )
    }

    func cancelTurn(sessionId: String, turnId: String, token: String) async throws {
        let es = sessionId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let et = turnId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let _: [String: AnyCodable] = try await request(
            path: "/api/agent/cancel-turn?sessionId=\(es)&turnId=\(et)",
            method: "POST",
            token: token
        )
    }

    private func request<T: Decodable>(
        path: String,
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        token: String,
        allowFailoverRetry: Bool = true
    ) async throws -> T {
        if activeBaseURL.isEmpty, let profile = activeProfile {
            _ = try await resolveReachableBaseURL(profile: profile)
        }

        do {
            return try await performSingleRequest(path: path, method: method, jsonBody: jsonBody, token: token)
        } catch let error as WEPError {
            throw error
        } catch {
            // Network/transport failure (e.g., switched from LAN Wi-Fi to 4G/5G or another Wi-Fi):
            // Immediately resolve reachable route (LAN <-> Tunnel) and retry once!
            if allowFailoverRetry, let profile = activeProfile {
                let previousBase = activeBaseURL
                if let resolved = try? await resolveReachableBaseURL(profile: profile) {
                    if resolved.baseURL != previousBase {
                        connectWebSocket(baseURL: resolved.baseURL, token: profile.token)
                    }
                    return try await performSingleRequest(path: path, method: method, jsonBody: jsonBody, token: token)
                }
            }
            throw error
        }
    }

    private func performSingleRequest<T: Decodable>(
        path: String,
        method: String,
        jsonBody: [String: Any]?,
        token: String
    ) async throws -> T {
        guard !activeBaseURL.isEmpty, let url = URL(string: activeBaseURL + path) else {
            throw WEPError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = (activeRouteLabel == "LAN") ? 5.0 : 16.0
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }

        let (data, resp) = try await apiSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw WEPError.httpError(0, "Invalid HTTP response")
        }

        if !(200...299).contains(http.statusCode) {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw WEPError.httpError(http.statusCode, msg)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WEPError.decodingError(error.localizedDescription)
        }
    }
}

struct AnyCodable: Codable {}
