#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

@Suite("Redirects")
struct RedirectTests {
    @Test func aRedirectStatusIsRefused() {
        let url = URL(string: "https://management.azure.com/x")!
        for status in [301, 302, 303, 307, 308] {
            #expect(throws: URLSessionTransport.RedirectRefused(status: status, location: "https://example.com/")) {
                try URLSessionTransport.check(status: status, location: "https://example.com/", requested: url, answered: url)
            }
        }
        #expect(throws: Never.self) { try URLSessionTransport.check(status: 200, location: nil, requested: url, answered: url) }
        #expect(throws: Never.self) { try URLSessionTransport.check(status: 404, location: nil, requested: url, answered: url) }
    }

    @Test func anAnswerFromAnotherOriginIsRefused() {
        let url = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        for other in ["https://example.com/common/oauth2/v2.0/token", "http://login.microsoftonline.com/common/oauth2/v2.0/token",
                      "https://login.microsoftonline.com:8443/common/oauth2/v2.0/token"] {
            #expect(throws: URLSessionTransport.RedirectRefused.self) {
                try URLSessionTransport.check(status: 200, location: nil, requested: url, answered: URL(string: other)!)
            }
        }
        // Same origin, another path or case: fine.
        #expect(throws: Never.self) {
            try URLSessionTransport.check(status: 200, location: nil, requested: url,
                                          answered: URL(string: "https://LOGIN.microsoftonline.com/other")!)
        }
    }

    /// Called through the protocol, so this fails if the method does not
    /// implement the requirement on this platform's Foundation.
    @Test func theDelegateDeclinesEveryRedirect() async {
        let delegate: URLSessionTaskDelegate = RedirectRefusal.shared
        let url = URL(string: "https://management.azure.com/x")!
        let task = URLSessionTransport.session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://example.com/"])!
        let next = await withCheckedContinuation { (continuation: CheckedContinuation<URLRequest?, Never>) in
            let next = URLRequest(url: URL(string: "https://example.com/")!)
            // An optional requirement in Apple's Foundation, one with a default in swift-corelibs-foundation.
            #if canImport(Darwin)
            delegate.urlSession?(URLSessionTransport.session, task: task, willPerformHTTPRedirection: response, newRequest: next) {
                continuation.resume(returning: $0)
            }
            #else
            delegate.urlSession(URLSessionTransport.session, task: task, willPerformHTTPRedirection: response, newRequest: next) {
                continuation.resume(returning: $0)
            }
            #endif
        }
        #expect(next == nil)
        task.cancel()
    }

    #if !os(Windows)
    @Test(arguments: [301, 302, 307, 308])
    func aRealRedirectIsNotFollowed(status: Int) async throws {
        let server = try TestHTTPServer { path in
            path == "/start" ? (status, ["Location": "/landed"]) : (200, [:])
        }
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/start")!)
        request.httpMethod = "POST"
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("refresh_token=secret".utf8)
        await #expect(throws: URLSessionTransport.RedirectRefused(status: status, location: "/landed")) {
            try await URLSessionTransport().send(request)
        }
        #expect(server.paths == ["/start"])
    }
    #endif
}

#if !os(Windows)
/// A minimal HTTP/1.1 server on 127.0.0.1 for tests: answers each request
/// with the status and headers `respond` gives for its path, an empty body,
/// and `Connection: close`; records the paths it saw.
final class TestHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var seen: [String] = []
    private var stopped = false
    private let done = DispatchSemaphore(value: 0)

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    init(respond: @escaping @Sendable (String) -> (Int, [String: String])) throws {
        let fd = LoopbackSocket.makeSocket(family: AF_INET) ?? -1
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard fd >= 0, bound == 0, listen(fd, 8) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.fd = fd
        port = UInt16(bigEndian: actual.sin_port)
        let thread = Thread { [self] in serve(respond) }
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        done.wait()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func serve(_ respond: (String) -> (Int, [String: String])) {
        defer {
            _ = TestSocket.close(fd)
            done.signal()
        }
        while !isStopped {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 50) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            var head = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !String(decoding: head, as: UTF8.self).contains("\r\n\r\n") {
                let n = recv(client, &buffer, buffer.count, 0)
                guard n > 0 else { break }
                head += buffer[0..<n]
            }
            let line = String(decoding: head, as: UTF8.self).split(separator: "\r\n").first ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            lock.lock()
            seen.append(path)
            lock.unlock()
            let (status, headers) = respond(path)
            var text = "HTTP/1.1 \(status) Status\r\nContent-Length: 0\r\nConnection: close\r\n"
            for (name, value) in headers { text += "\(name): \(value)\r\n" }
            TestSocket.sendAll(client, Array((text + "\r\n").utf8))
            _ = TestSocket.close(client)
        }
    }
}
#endif
