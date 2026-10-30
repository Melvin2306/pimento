#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
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

#if !os(Windows)
/// A one-shot HTTP listener on the loopback interface (127.0.0.1, and ::1 on
/// the same port when available) for the authorization code redirect. It
/// answers each request, ignores ones without our `state`, and stops at the
/// first callback with it, at the timeout, or when cancelled.
public final class LoopbackListener: @unchecked Sendable {
    /// Whether browser sign-in can work here (not on Windows, see below).
    public static let isSupported = true

    public let port: UInt16
    /// How long one connection may take to send its request head, in all:
    /// a client trickling bytes cannot hold the listener longer.
    let connectionTimeout: TimeInterval
    private var sockets: [Int32]
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
    /// ::1) does Pimento listen on 127.0.0.1 alone. `ports`: the 127.0.0.1
    /// port of each attempt (0: the kernel's choice; tests pick their own).
    init(connectionTimeout: TimeInterval, ports: [UInt16] = Array(repeating: 0, count: LoopbackListener.bindAttempts)) throws {
        try NetworkGuard.check("a sign-in listener on 127.0.0.1")
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
                _ = Self.closeSocket(v4)
            }
        }
        throw SignInError.loopback("could not listen on 127.0.0.1 and ::1 on the same port (\(ports.count) tries); "
            + "another program holds the ::1 side")
    }

    deinit { close() }

    private static var streamType: Int32 {
        #if canImport(Darwin)
        SOCK_STREAM
        #else
        Int32(SOCK_STREAM.rawValue)
        #endif
    }

    private static func closeSocket(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.close(fd)
        #else
        Glibc.close(fd)
        #endif
    }

    /// 127.0.0.1:`port` (0: any free port), listening; and the port it got.
    private static func bindIPv4Loopback(port requested: UInt16) throws -> (Int32, UInt16) {
        let v4 = socket(AF_INET, streamType, 0)
        guard v4 >= 0 else { throw SignInError.loopback(String(cString: strerror(errno))) }
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requested.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(v4, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(v4, 32) == 0 else {
            let message = String(cString: strerror(errno))
            _ = closeSocket(v4)
            throw SignInError.loopback(message)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(v4, $0, &length) }
        }
        return (v4, UInt16(bigEndian: actual.sin_port))
    }

    enum IPv6Bind: Equatable {
        case bound(Int32)
        /// No IPv6 loopback on this system: nobody can listen on ::1.
        case unavailable
        /// ::1 on this port is someone else's (or failed otherwise): try another port.
        case taken
    }

    /// Errors that mean the system has no IPv6 loopback, not that the port is taken.
    static func meansNoIPv6(_ code: Int32) -> Bool {
        code == EAFNOSUPPORT || code == EPROTONOSUPPORT || code == EADDRNOTAVAIL
    }

    static func bindIPv6Loopback(port: UInt16) -> IPv6Bind {
        let fd = socket(AF_INET6, streamType, 0)
        guard fd >= 0 else { return meansNoIPv6(errno) ? .unavailable : .taken }
        var on: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        #if canImport(Darwin)
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_loopback
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        if bound != 0 {
            let code = errno
            _ = closeSocket(fd)
            return meansNoIPv6(code) ? .unavailable : .taken
        }
        guard listen(fd, 32) == 0 else {
            _ = closeSocket(fd)
            return .taken
        }
        return .bound(fd)
    }

    /// Stops listening; a pending `waitForCallback` ends with `.cancelled`.
    /// While one is waiting, its thread closes the sockets (within 200 ms),
    /// so a descriptor is never closed under a running `poll`.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        if !serving { closeSockets() }
    }

    /// Call with `lock` held.
    private func closeSockets() {
        for fd in sockets { _ = Self.closeSocket(fd) }
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
        let fd: Int32
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
            for client in clients { _ = Self.closeSocket(client.fd) }
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
            var polls = (fds + clients.map(\.fd)).map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&polls, nfds_t(polls.count), wait)
            if isStopped { throw SignInError.cancelled }
            if ready < 0, errno != EINTR { throw SignInError.loopback(String(cString: strerror(errno))) }

            // Read from every connection that has something; answer the finished ones.
            var open: [Connection] = []
            for (i, var client) in clients.enumerated() {
                var done = client.deadline <= Date()
                if ready > 0, polls[fds.count + i].revents != 0, !done {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let n = recv(client.fd, &buffer, buffer.count, 0)
                    if n > 0 { client.head += buffer[0..<n] } else if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { done = true }
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
            for p in polls.prefix(fds.count) where p.revents & Int16(POLLIN) != 0 {
                let fd = accept(p.fd, nil, nil)
                guard fd >= 0 else { continue }
                Self.prepare(fd)
                // Added first, so `defer` closes it whatever `finish` does.
                clients.append(Connection(fd: fd, deadline: Date().addingTimeInterval(connectionTimeout)))
                if clients.count > Self.maxConnections, let code = try finish(clients.removeFirst()) { return code }
            }
        }
        throw SignInError.timedOut
    }

    /// A connection that never blocks the serving thread, and no SIGPIPE.
    private static func prepare(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Parses what `client` sent, answers it (what fits in the socket buffer:
    /// the page is small), closes the connection.
    private func answer(_ client: Connection, state: String) -> LoopbackCallback {
        defer { _ = Self.closeSocket(client.fd) }
        let callback = LoopbackRequest.parse(String(decoding: client.head, as: UTF8.self), expectedState: state)
        let response = [UInt8](LoopbackRequest.response(for: callback))
        var sent = 0
        while sent < response.count {
            #if canImport(Darwin)
            let n = response[sent...].withUnsafeBytes { send(client.fd, $0.baseAddress, $0.count, 0) }
            #else
            let n = response[sent...].withUnsafeBytes { send(client.fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            #endif
            guard n > 0 else { break }
            sent += n
        }
        return callback
    }
}

#else

/// Windows: no loopback listener yet (it would need Winsock), so no browser
/// sign-in; `pimento login` uses a device code instead.
public final class LoopbackListener: @unchecked Sendable {
    public static let isSupported = false
    public static let unsupportedMessage = "browser sign-in is not available on Windows; use `pimento login --device-code`"

    public let port: UInt16 = 0
    public var redirectURI: String { "\(MicrosoftIdentity.redirectBase):\(port)" }

    public init() throws { throw SignInError.loopback(Self.unsupportedMessage) }

    public func close() {}

    public func waitForCallback(state: String, timeout: TimeInterval) async throws -> String {
        throw SignInError.loopback(Self.unsupportedMessage)
    }
}
#endif
