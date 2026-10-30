#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif
import Foundation
@testable import PimentoCore

/// Client sockets for the loopback listener tests, on BSD sockets and
/// Winsock alike (through `LoopbackSocket`), so the same tests run on macOS,
/// Linux and Windows.
enum TestSocket {
    typealias Handle = LoopbackSocket.Handle

    @discardableResult
    static func close(_ fd: Handle) -> Int32 { LoopbackSocket.close(fd) }

    static func sendAll(_ fd: Handle, _ bytes: [UInt8]) {
        var sent = 0
        while sent < bytes.count {
            let n = LoopbackSocket.send(fd, bytes[sent...])
            guard n > 0 else { return }
            sent += n
        }
    }

    /// What has arrived (blocking until something has): the count, 0 at the end, -1 on an error.
    static func receive(_ fd: Handle, into buffer: inout [UInt8]) -> Int {
        LoopbackSocket.receive(fd, into: &buffer)
    }

    /// Whether `fd` can be read within `milliseconds`.
    static func waitReadable(_ fd: Handle, milliseconds: Int32) -> Bool {
        LoopbackSocket.poll([fd], milliseconds: milliseconds).ready > 0
    }

    /// A client connection to 127.0.0.1:`port`.
    static func connect(port: UInt16) -> Handle? {
        try? LoopbackSocket.startup()
        guard let fd = LoopbackSocket.makeSocket(family: AF_INET) else { return nil }
        #if canImport(Darwin)
        LoopbackSocket.setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
        #endif
        var addr = LoopbackSocket.ipv4Loopback(port: port)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                WinSDK.connect(fd, $0, Int32(MemoryLayout<sockaddr_in>.size))
                #elseif canImport(Darwin)
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Error codes of the platform's socket library, for `meansNoIPv6`.
    #if os(Windows)
    static let noAddressFamily = Int32(WSAEAFNOSUPPORT), addressNotAvailable = Int32(WSAEADDRNOTAVAIL)
    static let addressInUse = Int32(WSAEADDRINUSE), accessDenied = Int32(WSAEACCES)
    #else
    static let noAddressFamily = EAFNOSUPPORT, addressNotAvailable = EADDRNOTAVAIL
    static let addressInUse = EADDRINUSE, accessDenied = EACCES
    #endif
}

/// Acts as the browser: sends `GET target` to the loopback listener on `port`
/// and returns the whole answer.
@discardableResult
func browse(port: UInt16, _ target: String) -> String {
    guard let fd = TestSocket.connect(port: port) else { return "" }
    defer { TestSocket.close(fd) }
    TestSocket.sendAll(fd, Array("GET \(target) HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n".utf8))
    var response = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = TestSocket.receive(fd, into: &buffer)
        guard n > 0 else { break }
        response += buffer[0..<n]
    }
    return String(decoding: response, as: UTF8.self)
}
