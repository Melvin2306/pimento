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

/// A one-shot HTTP listener on the loopback interface (127.0.0.1, and ::1 on
/// the same port when available) for the authorization code redirect. It
/// answers each request, ignores ones without our `state`, and stops at the
/// first callback with it, at the timeout, or when cancelled.
public final class LoopbackListener: @unchecked Sendable {
    public let port: UInt16
    private var sockets: [Int32]
    private let lock = NSLock()
    private var stopped = false
    private var serving = false

    /// `http://localhost:<port>`: Entra ignores the port of a localhost redirect URI.
    public var redirectURI: String { "\(MicrosoftIdentity.redirectBase):\(port)" }

    public init() throws {
        let v4 = socket(AF_INET, Self.streamType, 0)
        guard v4 >= 0 else { throw SignInError.loopback(String(cString: strerror(errno))) }
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(v4, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(v4, 8) == 0 else {
            let message = String(cString: strerror(errno))
            _ = Self.closeSocket(v4)
            throw SignInError.loopback(message)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(v4, $0, &length) }
        }
        port = UInt16(bigEndian: actual.sin_port)
        sockets = [v4]
        // Browsers may resolve localhost to ::1 first; listen there too if we can.
        if let v6 = Self.bindIPv6Loopback(port: port) { sockets.append(v6) }
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

    private static func bindIPv6Loopback(port: UInt16) -> Int32? {
        let fd = socket(AF_INET6, streamType, 0)
        guard fd >= 0 else { return nil }
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
        guard bound == 0, listen(fd, 8) == 0 else {
            _ = closeSocket(fd)
            return nil
        }
        return fd
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

    private func serve(state: String, deadline: Date) throws -> String {
        lock.lock()
        let fds = stopped ? [] : sockets
        serving = true
        lock.unlock()
        defer {
            lock.lock()
            stopped = true
            serving = false
            closeSockets()
            lock.unlock()
        }
        guard !fds.isEmpty else { throw SignInError.cancelled }
        while Date() < deadline {
            if isStopped { throw SignInError.cancelled }
            var polls = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&polls, nfds_t(polls.count), 200)
            if isStopped { throw SignInError.cancelled }
            guard ready > 0 else { continue }
            for p in polls where p.revents & Int16(POLLIN) != 0 {
                let client = accept(p.fd, nil, nil)
                guard client >= 0 else { continue }
                let callback = handle(client, state: state)
                switch callback {
                case .code(let code): return code
                case .error(let info): throw info.needsInteraction ? SignInError.interactionRequired(info) : SignInError.oauth(info)
                case .stateMismatch, .ignored: continue
                }
            }
        }
        throw SignInError.timedOut
    }

    /// Reads one request head (up to 16 KB, 5 s), answers it, closes the connection.
    private func handle(_ client: Int32, state: String) -> LoopbackCallback {
        defer { _ = Self.closeSocket(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var head = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while head.count < 16384 {
            let n = recv(client, &buffer, buffer.count, 0)
            guard n > 0 else { break }
            head += buffer[0..<n]
            if String(decoding: head, as: UTF8.self).contains("\r\n\r\n") { break }
        }
        let callback = LoopbackRequest.parse(String(decoding: head, as: UTF8.self), expectedState: state)
        let response = [UInt8](LoopbackRequest.response(for: callback))
        var sent = 0
        while sent < response.count {
            #if canImport(Darwin)
            let n = response[sent...].withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            #else
            let n = response[sent...].withUnsafeBytes { send(client, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            #endif
            guard n > 0 else { break }
            sent += n
        }
        return callback
    }
}
