#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif
import Foundation

/// What the browser brought back to the loopback redirect.
public enum LoopbackCallback: Equatable, Sendable {
    /// The authorization code, with the expected `state`.
    case code(String)
    /// The identity platform reported an error, with the expected `state`.
    case error(OAuthErrorInfo)
    /// A redirect with another (or no) `state`: not ours, ignored.
    case stateMismatch
    /// Anything else (`/favicon.ico`, a stray request).
    case ignored
}

public enum LoopbackRequest {
    /// Reads the request head of one browser request to the redirect URI.
    public static func parse(_ head: String, expectedState: String) -> LoopbackCallback {
        guard let line = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first
                ?? head.split(separator: "\n").first else { return .ignored }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return .ignored }
        let target = String(parts[1])
        let (path, query) = target.firstIndex(of: "?").map { (String(target[..<$0]), String(target[target.index(after: $0)...])) }
            ?? (target, "")
        guard path == "/" || path.isEmpty, !query.isEmpty else { return .ignored }
        let fields = TokenRequest.formDecode(query)
        let stateMatches = fields["state"].map { constantTimeEqual($0, expectedState) } ?? false
        if let error = fields["error"], !error.isEmpty {
            guard stateMatches else { return .stateMismatch }
            return .error(OAuthErrorInfo(error: error, description: fields["error_description"], claims: fields["claims"],
                                         suberror: fields["error_subcode"]))
        }
        guard let code = fields["code"], !code.isEmpty else { return .ignored }
        return stateMatches ? .code(code) : .stateMismatch
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The HTTP response for a callback: a small page that says what happened.
    public static func response(for callback: LoopbackCallback) -> Data {
        let (status, title, text): (String, String, String) = switch callback {
        case .code: ("200 OK", "Signed in", "You are signed in to \(AppInfo.name). You can close this tab.")
        case .error(let info): ("400 Bad Request", "Sign-in failed", info.message)
        case .stateMismatch: ("400 Bad Request", "Not for this sign-in", "This answer does not belong to the sign-in \(AppInfo.name) started. You can close this tab.")
        case .ignored: ("404 Not Found", "Not found", "")
        }
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title)) · \(AppInfo.name)</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;margin:15vh auto;max-width:32em;padding:0 1em;color:#222}
        @media (prefers-color-scheme:dark){body{background:#1e1e1e;color:#eee}}h1{font-size:1.4em}</style></head>
        <body><h1>\(escape(title))</h1><p>\(escape(text))</p></body></html>
        """
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Cache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n"
            + "Referrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        return Data((head + body).utf8)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}


/// A one-shot HTTP listener on the loopback interface (127.0.0.1, and ::1 on
/// the same port when available) for the authorization code redirect. It
/// answers each request, ignores ones without our `state`, and stops at the
/// first callback with it, at the timeout, or when cancelled. The same code
/// on every platform: BSD sockets on macOS and Linux, Winsock on Windows
/// (`LoopbackSocket`).
public final class LoopbackListener: @unchecked Sendable {
    /// Whether browser sign-in can work here: on macOS, Linux and Windows.
    public static let isSupported = true

    public let port: UInt16
    /// How long one connection may take to send its request head, in all:
    /// a client trickling bytes cannot hold the listener longer.
    let connectionTimeout: TimeInterval
    private var sockets: [LoopbackSocket.Handle]
    private let lock = NSLock()
    private var stopped = false
    private var serving = false

    /// `http://localhost:<port>`: Entra ignores the port of a localhost redirect URI.
    public var redirectURI: String { "\(MicrosoftIdentity.redirectBase):\(port)" }

    public convenience init() throws { try self.init(connectionTimeout: 5) }

    /// How many ports `init` tries before it gives up.
    static let bindAttempts = 16

    /// Listens on 127.0.0.1 and ::1 on one port. The redirect URI names
    /// `localhost`, which a browser may resolve to ::1 first, so the ::1
    /// side must be Pimento's too: when ::1 on the port the kernel chose for
    /// 127.0.0.1 is taken (by another program or user, which would then get
    /// the redirect with the code and state), the port is dropped and
    /// another one tried; after `bindAttempts` ports, sign-in fails. Only
    /// where the system has no IPv6 loopback at all (so nobody can listen on
    /// ::1) does Pimento listen on 127.0.0.1 alone. On Windows both sockets
    /// are exclusive (`SO_EXCLUSIVEADDRUSE`): no other program can bind the
    /// port after them, not even with `SO_REUSEADDR`. `ports`: the 127.0.0.1
    /// port of each attempt (0: the kernel's choice; tests pick their own).
    init(connectionTimeout: TimeInterval, ports: [UInt16] = Array(repeating: 0, count: LoopbackListener.bindAttempts)) throws {
        try NetworkGuard.check("a sign-in listener on 127.0.0.1")
        try LoopbackSocket.startup()
        self.connectionTimeout = connectionTimeout
        for candidate in ports {
            let (v4, port) = try Self.bindIPv4Loopback(port: candidate)
            switch Self.bindIPv6Loopback(port: port) {
            case .bound(let v6):
                self.port = port
                sockets = [v4, v6]
                return
            case .unavailable:
                self.port = port
                sockets = [v4]
                return
            case .taken:
                LoopbackSocket.close(v4)
            }
        }
        throw SignInError.loopback("could not listen on 127.0.0.1 and ::1 on the same port (\(ports.count) tries); "
            + "another program holds the ::1 side")
    }

    deinit { close() }

    /// 127.0.0.1:`port` (0: any free port), listening; and the port it got.
    private static func bindIPv4Loopback(port requested: UInt16) throws -> (LoopbackSocket.Handle, UInt16) {
        guard let v4 = LoopbackSocket.makeSocket(family: AF_INET) else {
            throw SignInError.loopback(LoopbackSocket.describe(LoopbackSocket.lastError))
        }
        guard LoopbackSocket.makeExclusive(v4), LoopbackSocket.bind(v4, to: LoopbackSocket.ipv4Loopback(port: requested)),
              LoopbackSocket.listen(v4), let port = LoopbackSocket.localPort(v4) else {
            let message = LoopbackSocket.describe(LoopbackSocket.lastError)
            LoopbackSocket.close(v4)
            throw SignInError.loopback(message)
        }
        return (v4, port)
    }

    enum IPv6Bind: Equatable {
        case bound(LoopbackSocket.Handle)
        /// No IPv6 loopback on this system: nobody can listen on ::1.
        case unavailable
        /// ::1 on this port is someone else's (or failed otherwise): try another port.
        case taken
    }

    /// Errors that mean the system has no IPv6 loopback, not that the port is taken.
    static func meansNoIPv6(_ code: Int32) -> Bool { LoopbackSocket.meansNoIPv6(code) }

    static func bindIPv6Loopback(port: UInt16) -> IPv6Bind {
        guard let fd = LoopbackSocket.makeSocket(family: AF_INET6) else {
            return meansNoIPv6(LoopbackSocket.lastError) ? .unavailable : .taken
        }
        LoopbackSocket.setIPv6Only(fd)
        guard LoopbackSocket.makeExclusive(fd) else {
            LoopbackSocket.close(fd)
            return .taken
        }
        if !LoopbackSocket.bind(fd, to: LoopbackSocket.ipv6Loopback(port: port)) {
            let code = LoopbackSocket.lastError
            LoopbackSocket.close(fd)
            return meansNoIPv6(code) ? .unavailable : .taken
        }
        guard LoopbackSocket.listen(fd) else {
            LoopbackSocket.close(fd)
            return .taken
        }
        return .bound(fd)
    }

    /// Stops listening; a pending `waitForCallback` ends with `.cancelled`.
    /// While one is waiting, its thread closes the sockets (within 200 ms),
    /// so a socket is never closed under a running `poll`.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        if !serving { closeSockets() }
    }

    /// Call with `lock` held.
    private func closeSockets() {
        for fd in sockets { LoopbackSocket.close(fd) }
        sockets = []
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Waits for the redirect carrying `state` and returns its code. Throws
    /// the identity platform's error, `.timedOut`, or `.cancelled`.
    public func waitForCallback(state: String, timeout: TimeInterval) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let thread = Thread { [self] in
                    continuation.resume(with: Result { try self.serve(state: state, deadline: Date().addingTimeInterval(timeout)) })
                }
                thread.name = "Pimento loopback"
                thread.start()
            }
        } onCancel: {
            close()
        }
    }

    /// How many connections are served at once. A client that connects
    /// beyond that pushes out the oldest one (it has had the most time), so
    /// stray or slow connections cannot keep the browser's redirect out.
    static let maxConnections = 16

    /// One open connection: its request head so far and its own deadline.
    private struct Connection {
        let fd: LoopbackSocket.Handle
        let deadline: Date
        var head: [UInt8] = []

        /// The head is complete (or as long as it may get).
        var isComplete: Bool {
            head.count >= LoopbackListener.maxHead || String(decoding: head, as: UTF8.self).contains("\r\n\r\n")
        }
    }

    /// The longest request head read.
    static let maxHead = 16384

    /// Serves every connection side by side on this one thread: each gets
    /// `connectionTimeout` in all to send its request head, and none waits
    /// for another, so a connection that sends nothing (or trickles) delays
    /// nobody. At most `maxConnections` are open at once.
    private func serve(state: String, deadline: Date) throws -> String {
        lock.lock()
        let fds = stopped ? [] : sockets
        serving = true
        lock.unlock()
        var clients: [Connection] = []
        defer {
            for client in clients { LoopbackSocket.close(client.fd) }
            lock.lock()
            stopped = true
            serving = false
            closeSockets()
            lock.unlock()
        }
        guard !fds.isEmpty else { throw SignInError.cancelled }
        /// Answers `client`, closes it; the code or error ends the wait.
        func finish(_ client: Connection) throws -> String? {
            switch answer(client, state: state) {
            case .code(let code): return code
            case .error(let info): throw info.needsInteraction ? SignInError.interactionRequired(info) : SignInError.oauth(info)
            case .stateMismatch, .ignored: return nil
            }
        }
        while Date() < deadline {
            if isStopped { throw SignInError.cancelled }
            // Wake up for the nearest connection deadline, at most every 200 ms.
            let nearest = clients.map { $0.deadline.timeIntervalSinceNow }.min() ?? 0.2
            let wait = Int32((min(0.2, max(0, nearest)) * 1000).rounded(.up))
            let (ready, events, pollError) = LoopbackSocket.poll(fds + clients.map(\.fd), milliseconds: wait)
            if isStopped { throw SignInError.cancelled }
            if ready < 0, !LoopbackSocket.isTransient(pollError) { throw SignInError.loopback(LoopbackSocket.describe(pollError)) }

            // Read from every connection that has something; answer the finished ones.
            var open: [Connection] = []
            for (i, var client) in clients.enumerated() {
                var done = client.deadline <= Date()
                if ready > 0, events[fds.count + i] != 0, !done {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let n = LoopbackSocket.receive(client.fd, into: &buffer)
                    if n > 0 {
                        client.head += buffer[0..<n]
                    } else if n == 0 || !LoopbackSocket.isTransient(LoopbackSocket.lastError) {
                        done = true
                    }
                    if client.isComplete { done = true }
                }
                if done {
                    // `client` is closed either way; the rest stay for `defer`.
                    let result: String?
                    do { result = try finish(client) } catch {
                        clients = open + clients.dropFirst(i + 1)
                        throw error
                    }
                    if let code = result {
                        clients = open + clients.dropFirst(i + 1)
                        return code
                    }
                } else {
                    open.append(client)
                }
            }
            clients = open

            guard ready > 0 else { continue }
            for (index, revents) in events.prefix(fds.count).enumerated() where revents & LoopbackSocket.readable != 0 {
                guard let fd = LoopbackSocket.accept(fds[index]) else { continue }
                LoopbackSocket.prepare(fd)
                // Added first, so `defer` closes it whatever `finish` does.
                clients.append(Connection(fd: fd, deadline: Date().addingTimeInterval(connectionTimeout)))
                if clients.count > Self.maxConnections, let code = try finish(clients.removeFirst()) { return code }
            }
        }
        throw SignInError.timedOut
    }

    /// Parses what `client` sent, answers it (what fits in the socket buffer:
    /// the page is small), ends the connection.
    private func answer(_ client: Connection, state: String) -> LoopbackCallback {
        defer { LoopbackSocket.finish(client.fd) }
        let callback = LoopbackRequest.parse(String(decoding: client.head, as: UTF8.self), expectedState: state)
        let response = [UInt8](LoopbackRequest.response(for: callback))
        var sent = 0
        while sent < response.count {
            let n = LoopbackSocket.send(client.fd, response[sent...])
            guard n > 0 else { break }
            sent += n
        }
        return callback
    }
}
