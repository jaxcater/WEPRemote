import Foundation

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

final class WEPClient {
    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    private(set) var activeBaseURL: String = ""
    private(set) var activeRouteLabel: String = "Disconnected"

    var onWebSocketEvent: ((String, [String: Any]) -> Void)?
    var onConnectionStateChange: ((Bool, String) -> Void)?

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: cfg)
    }

    func resolveAndConnect(profile: HostProfile) async throws {
        // Try LAN first with short timeout for instant speed at home, then fallback to Cloudflare Tunnel.
        if let lan = profile.lanUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !lan.isEmpty {
            if await probeHealth(baseURL: lan, token: profile.token, timeout: 1.1) {
                activeBaseURL = lan.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                activeRouteLabel = "LAN"
                connectWebSocket(baseURL: activeBaseURL, token: profile.token)
                return
            }
        }

        if let tunnel = profile.tunnelUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !tunnel.isEmpty {
            if await probeHealth(baseURL: tunnel, token: profile.token, timeout: 6.0) {
                activeBaseURL = tunnel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                activeRouteLabel = "Tunnel"
                connectWebSocket(baseURL: activeBaseURL, token: profile.token)
                return
            }
        }

        // If neither probe responded immediately, set best available URL and throw.
        let fallback = (profile.tunnelUrl?.isEmpty == false ? profile.tunnelUrl : profile.lanUrl) ?? ""
        activeBaseURL = fallback.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        activeRouteLabel = "Offline"
        onConnectionStateChange?(false, "Offline")
        throw WEPError.httpError(0, "Could not reach Windows host via LAN or Cloudflare Tunnel.")
    }

    func disconnectWebSocket() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        onConnectionStateChange?(false, "Disconnected")
    }

    private func probeHealth(baseURL: String, token: String, timeout: TimeInterval) async -> Bool {
        let clean = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(clean)/api/health") else { return false }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let health = try JSONDecoder().decode(HealthResponse.self, from: data)
            return health.ok && (health.authenticated ?? false)
        } catch {
            return false
        }
    }

    private func connectWebSocket(baseURL: String, token: String) {
        disconnectWebSocket()

        let wsScheme = baseURL.hasPrefix("https://")
            ? "wss://" + baseURL.dropFirst("https://".count)
            : (baseURL.hasPrefix("http://") ? "ws://" + baseURL.dropFirst("http://".count) : "wss://\(baseURL)")

        guard let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let wsURL = URL(string: "\(wsScheme)/ws?token=\(encodedToken)") else {
            return
        }

        let task = session.webSocketTask(with: wsURL)
        self.webSocketTask = task
        task.resume()
        onConnectionStateChange?(true, activeRouteLabel)

        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
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
                    }
                    break
                }
            }
        }
    }

    func sendWebSocketJSON(_ object: [String: Any]) async throws {
        guard let task = webSocketTask else {
            throw WEPError.notConfigured
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let str = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(str))
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

    func listSessions(token: String) async throws -> [SessionRecord] {
        try await request(path: "/api/sessions", token: token)
    }

    func getSession(id: String, token: String) async throws -> SessionRecord {
        try await request(path: "/api/sessions/\(id)", token: token)
    }

    func createSession(workspacePath: String, model: String, mode: String, token: String) async throws -> SessionRecord {
        let body: [String: Any] = [
            "workspacePath": workspacePath,
            "model": model,
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

    func startAgent(
        sessionId: String?,
        workspacePath: String,
        prompt: String,
        model: String,
        mode: String,
        skipPermissions: Bool,
        attachedFiles: [String],
        token: String
    ) async throws {
        var body: [String: Any] = [
            "workspacePath": workspacePath,
            "prompt": prompt,
            "model": model,
            "mode": mode,
            "skipPermissions": skipPermissions,
            "attachedFiles": attachedFiles
        ]
        if let sessionId { body["sessionId"] = sessionId }
        let _: [String: AnyCodable] = try await request(path: "/api/agent/start", method: "POST", jsonBody: body, token: token)
    }

    func cancelAgent(sessionId: String, token: String) async throws {
        let es = sessionId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let _: [String: AnyCodable] = try await request(path: "/api/agent/cancel?sessionId=\(es)", method: "POST", token: token)
    }

    private func request<T: Decodable>(
        path: String,
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        token: String
    ) async throws -> T {
        guard !activeBaseURL.isEmpty, let url = URL(string: activeBaseURL + path) else {
            throw WEPError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }

        let (data, resp) = try await session.data(for: req)
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
