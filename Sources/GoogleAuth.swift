import AppKit
import CryptoKit
import Foundation
import Network

// MARK: - Files

struct OAuthClient: Decodable {
    let client_id: String
    let client_secret: String?
    let token_uri: String?
    let project_id: String?
}

private struct ClientFile: Decodable {
    let installed: OAuthClient?
    let web: OAuthClient?
}

struct TokenSet: Codable {
    var refreshToken: String
    var accessToken: String?
    var expiry: Date?
    var scopes: String? = nil
}

/// ~/Library/Application Support/Islet — files are only readable by this user (0600).
enum Storage {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Islet", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }
    static var clientURL: URL { dir.appendingPathComponent("google_client.json") }
    static var tokenURL: URL { dir.appendingPathComponent("google_token.json") }

    static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum GoogleError: LocalizedError {
    case noClient
    case badClient
    case cancelled
    case invalidGrant
    case apiDisabled
    case insufficientScope
    case http(Int, String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .noClient: return "No Google client file yet."
        case .badClient: return "That file isn't a Google OAuth client JSON."
        case .cancelled: return "Sign-in was cancelled."
        case .invalidGrant: return "Google signed you out. Please sign in again."
        case .apiDisabled: return "That Google API is turned off for this project."
        case .insufficientScope: return "Islet needs one more permission. Sign in again."
        case .http(let code, let msg): return "Google error \(code): \(msg)"
        case .other(let msg): return msg
        }
    }
}

// MARK: - OAuth (installed-app flow with PKCE + loopback redirect)

@MainActor
final class GoogleAuth {
    static let scope = "https://www.googleapis.com/auth/calendar.readonly"

    private(set) var client: OAuthClient?
    private var tokens: TokenSet?
    private var server: LoopbackServer?

    var hasClient: Bool { client != nil }
    var isSignedIn: Bool { tokens != nil }
    var projectID: String? { client?.project_id }

    init() {
        loadClient()
        if let data = try? Data(contentsOf: Storage.tokenURL) {
            tokens = try? JSONDecoder().decode(TokenSet.self, from: data)
        }
    }

    func loadClient() {
        guard let data = try? Data(contentsOf: Storage.clientURL),
              let f = try? JSONDecoder().decode(ClientFile.self, from: data) else {
            client = nil
            return
        }
        client = f.installed ?? f.web
    }

    func importClient(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let f = try? JSONDecoder().decode(ClientFile.self, from: data), (f.installed ?? f.web) != nil else {
            throw GoogleError.badClient
        }
        try Storage.writePrivate(data, to: Storage.clientURL)
        loadClient()
    }

    private func saveTokens() {
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }
        try? Storage.writePrivate(data, to: Storage.tokenURL)
    }

    func signOut() {
        tokens = nil
        try? FileManager.default.removeItem(at: Storage.tokenURL)
    }

    func cancelSignIn() {
        server?.stop()
        server = nil
    }

    /// Opens Google's consent page in the browser and waits for the redirect back to 127.0.0.1.
    func signIn() async throws {
        guard let client else { throw GoogleError.noClient }
        server?.stop()

        let verifier = Self.randomURLSafe(64)
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(24)

        let srv = LoopbackServer()
        server = srv
        let port = try await srv.start()
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: client.client_id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = comps.url else { throw GoogleError.other("Couldn't build sign-in URL") }
        NSWorkspace.shared.open(url)

        let params = try await srv.waitForCallback()
        srv.stop()
        server = nil

        guard params["state"] == state else { throw GoogleError.other("Sign-in response didn't match. Try again.") }
        if let err = params["error"] {
            throw err == "access_denied" ? GoogleError.cancelled : GoogleError.other(err)
        }
        guard let code = params["code"] else { throw GoogleError.other("Google didn't send a sign-in code.") }

        let r = try await tokenRequest([
            "code": code,
            "client_id": client.client_id,
            "client_secret": client.client_secret ?? "",
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refresh = r.refresh_token else {
            throw GoogleError.other("Google didn't return a refresh token. Try signing in again.")
        }
        tokens = TokenSet(refreshToken: refresh, accessToken: r.access_token,
                          expiry: Date().addingTimeInterval(TimeInterval(r.expires_in ?? 3600) - 60),
                          scopes: r.scope)
        saveTokens()
    }

    func expireAccessToken() {
        tokens?.accessToken = nil
    }

    func accessToken() async throws -> String {
        guard let client else { throw GoogleError.noClient }
        guard var t = tokens else { throw GoogleError.invalidGrant }
        if let a = t.accessToken, let e = t.expiry, e > Date() { return a }
        do {
            let r = try await tokenRequest([
                "client_id": client.client_id,
                "client_secret": client.client_secret ?? "",
                "refresh_token": t.refreshToken,
                "grant_type": "refresh_token",
            ])
            t.accessToken = r.access_token
            t.expiry = Date().addingTimeInterval(TimeInterval(r.expires_in ?? 3600) - 60)
            if let nr = r.refresh_token { t.refreshToken = nr }
            if let sc = r.scope { t.scopes = sc }
            tokens = t
            saveTokens()
            return r.access_token
        } catch GoogleError.invalidGrant {
            signOut()
            throw GoogleError.invalidGrant
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
        let scope: String?
    }

    private struct TokenError: Decodable {
        let error: String
        let error_description: String?
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: client?.token_uri ?? "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 { return try JSONDecoder().decode(TokenResponse.self, from: data) }
        let err = try? JSONDecoder().decode(TokenError.self, from: data)
        if err?.error == "invalid_grant" { throw GoogleError.invalidGrant }
        throw GoogleError.http(status, err?.error_description ?? err?.error ?? "Token request failed")
    }

    // MARK: Utils

    private static func randomURLSafe(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars[Int(rng.next() % UInt64(chars.count))] })
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - Tiny HTTP server on 127.0.0.1 that catches Google's redirect

final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "islet.oauth.loopback")
    private var listener: NWListener?
    private var readyCont: CheckedContinuation<UInt16, Error>?
    private var callbackCont: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: .any)
        listener = l
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.readyCont = cont
                l.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let p = l.port?.rawValue {
                            self.readyCont?.resume(returning: p)
                            self.readyCont = nil
                        }
                    case .failed(let e):
                        self.readyCont?.resume(throwing: e)
                        self.readyCont = nil
                        self.finish(.failure(e))
                    case .cancelled:
                        self.readyCont?.resume(throwing: CancellationError())
                        self.readyCont = nil
                    default:
                        break
                    }
                }
                l.newConnectionHandler = { [weak self] c in self?.handle(c) }
                l.start(queue: self.queue)
            }
        }
    }

    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let r = self.result {
                    cont.resume(with: r)
                } else {
                    self.callbackCont = cont
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.finish(.failure(CancellationError()))
        }
    }

    /// Must be called on `queue`.
    private func finish(_ r: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = r
        callbackCont?.resume(with: r)
        callbackCont = nil
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, _, _ in
            guard let self else { c.cancel(); return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = text.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2,
                  let comps = URLComponents(string: "http://127.0.0.1" + parts[1]),
                  let items = comps.queryItems,
                  items.contains(where: { $0.name == "code" || $0.name == "error" }) else {
                self.respond(c, status: "404 Not Found", body: "")
                return
            }
            var params: [String: String] = [:]
            for q in items { params[q.name] = q.value ?? "" }
            self.respond(c, status: "200 OK", body: Self.page(success: params["code"] != nil))
            self.finish(.success(params))
        }
    }

    private func respond(_ c: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in c.cancel() })
    }

    private static func page(success: Bool) -> String {
        let title = success ? "You're connected" : "Sign-in didn't finish"
        let sub = success ? "Islet can now see your Google Calendar. You can close this tab."
                          : "Head back to Islet and try again."
        let mark = success ? "✓" : "!"
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Islet</title>
        <style>
        body{margin:0;height:100vh;display:grid;place-items:center;background:#0b0b0c;color:#f5f5f7;
        font:16px -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
        .card{background:#000;border-radius:28px;padding:36px 44px;text-align:center;
        box-shadow:0 20px 60px rgba(0,0,0,.6),0 0 0 1px rgba(255,255,255,.06)}
        .dot{width:56px;height:56px;border-radius:50%;margin:0 auto 18px;display:grid;place-items:center;
        font-size:26px;background:rgba(52,211,153,.15);color:#34d399}
        h1{font-size:22px;margin:0 0 6px}p{margin:0;color:rgba(245,245,247,.55)}
        </style></head><body><div class="card"><div class="dot">\(mark)</div>
        <h1>\(title)</h1><p>\(sub)</p></div></body></html>
        """
    }
}
