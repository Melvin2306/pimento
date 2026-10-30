#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif
import Foundation

/// The socket calls of the loopback listener, over BSD sockets (macOS, Linux)
/// and Winsock (Windows), so that one listener, with one set of rules, serves
/// every platform. Error codes are `errno` values, or `WSAGetLastError()`
/// codes on Windows; read `lastError` right after the call that failed.
enum LoopbackSocket {
    #if os(Windows)
    typealias Handle = SOCKET
    typealias Length = Int32
    /// `INVALID_SOCKET` (`(SOCKET)(~0)`, which Swift does not import).
    static let invalid: Handle = ~0
    #else
    typealias Handle = Int32
    typealias Length = socklen_t
    #endif

    /// The error of the last socket call on this thread.
    static var lastError: Int32 {
        #if os(Windows)
        WSAGetLastError()
        #else
        errno
        #endif
    }

    static func describe(_ code: Int32) -> String {
        #if os(Windows)
        "Winsock error \(code)"
        #else
        String(cString: strerror(code))
        #endif
    }

    #if os(Windows)
    /// `WSAStartup`'s answer, once per process (Winsock counts the calls; the
    /// process ends with it started).
    private static let startupResult: Int32 = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data)
    }()
    #endif

    /// Makes sure the socket library is ready (Winsock needs `WSAStartup`).
    static func startup() throws {
        #if os(Windows)
        guard startupResult == 0 else { throw SignInError.loopback("Winsock did not start (error \(startupResult))") }
        #endif
    }

    private static var streamType: Int32 {
        #if canImport(Glibc)
        Int32(SOCK_STREAM.rawValue)
        #else
        SOCK_STREAM
        #endif
    }

    /// A new TCP socket of `family` (`AF_INET` or `AF_INET6`), nil on failure.
    static func makeSocket(family: Int32) -> Handle? {
        #if os(Windows)
        let handle = socket(family, streamType, 0)
        return handle == invalid ? nil : handle
        #else
        let fd = socket(family, streamType, 0)
        return fd >= 0 ? fd : nil
        #endif
    }

    @discardableResult
    static func close(_ handle: Handle) -> Int32 {
        #if os(Windows)
        closesocket(handle)
        #elseif canImport(Darwin)
        Darwin.close(handle)
        #else
        Glibc.close(handle)
        #endif
    }

    /// Sets an integer socket option; false when the system refused it.
    @discardableResult
    static func setOption(_ handle: Handle, _ level: Int32, _ name: Int32, _ value: Int32) -> Bool {
        var value = value
        #if os(Windows)
        return withUnsafeBytes(of: &value) {
            setsockopt(handle, level, name, $0.baseAddress!.assumingMemoryBound(to: CChar.self), Int32($0.count))
        } == 0
        #else
        return setsockopt(handle, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0
        #endif
    }

    /// Windows: no other socket may bind this socket's address and port, not
    /// even one with `SO_REUSEADDR`, which Windows otherwise lets take over a
    /// port in use (and with it the redirect). Set before `bind`. BSD sockets
    /// refuse that already, so elsewhere this does nothing.
    static func makeExclusive(_ handle: Handle) -> Bool {
        #if os(Windows)
        // SO_EXCLUSIVEADDRUSE is `((int)(~SO_REUSEADDR))`, which Swift does not import.
        setOption(handle, SOL_SOCKET, ~SO_REUSEADDR, 1)
        #else
        true
        #endif
    }

    /// An IPv6 socket for IPv6 only (Windows' default too, but not Linux's).
    static func setIPv6Only(_ handle: Handle) {
        #if os(Windows)
        setOption(handle, Int32(IPPROTO_IPV6.rawValue), IPV6_V6ONLY, 1)
        #else
        setOption(handle, Int32(IPPROTO_IPV6), IPV6_V6ONLY, 1)
        #endif
    }

    /// 127.0.0.1:`port`.
    static func ipv4Loopback(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        #if os(Windows)
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        addr.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
        #else
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        #endif
        addr.sin_port = port.bigEndian
        return addr
    }

    /// [::1]:`port`.
    static func ipv6Loopback(port: UInt16) -> sockaddr_in6 {
        var addr = sockaddr_in6()
        #if canImport(Darwin)
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        #if os(Windows)
        addr.sin6_family = ADDRESS_FAMILY(AF_INET6)
        addr.sin6_addr.u.Byte.15 = 1
        #else
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_addr = in6addr_loopback
        #endif
        addr.sin6_port = port.bigEndian
        return addr
    }

    /// Binds `handle` to `address` (a `sockaddr_in` or `sockaddr_in6`).
    static func bind<Address>(_ handle: Handle, to address: Address) -> Bool {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                WinSDK.bind(handle, $0, Length(MemoryLayout<Address>.size))
                #elseif canImport(Darwin)
                Darwin.bind(handle, $0, Length(MemoryLayout<Address>.size))
                #else
                Glibc.bind(handle, $0, Length(MemoryLayout<Address>.size))
                #endif
            }
        } == 0
    }

    static func listen(_ handle: Handle) -> Bool {
        #if os(Windows)
        WinSDK.listen(handle, 32) == 0
        #elseif canImport(Darwin)
        Darwin.listen(handle, 32) == 0
        #else
        Glibc.listen(handle, 32) == 0
        #endif
    }

    /// The local port of a bound socket (IPv4 or IPv6).
    static func localPort(_ handle: Handle) -> UInt16? {
        var storage = sockaddr_storage()
        var length = Length(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(handle, $0, &length) }
        }
        guard named == 0 else { return nil }
        // `sin_port` and `sin6_port` are at the same offset.
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
    }

    /// The next waiting connection, nil when there is none (or on an error).
    static func accept(_ handle: Handle) -> Handle? {
        #if os(Windows)
        let client = WinSDK.accept(handle, nil, nil)
        return client == invalid ? nil : client
        #elseif canImport(Darwin)
        let fd = Darwin.accept(handle, nil, nil)
        return fd >= 0 ? fd : nil
        #else
        let fd = Glibc.accept(handle, nil, nil)
        return fd >= 0 ? fd : nil
        #endif
    }

    #if os(Windows)
    /// `FIONBIO` (`_IOW('f', 126, u_long)`, which Swift does not import).
    private static let nonBlockingIO = Int32(bitPattern: 0x8004_667E)
    #endif

    /// A connection that never blocks the serving thread, and no SIGPIPE.
    static func prepare(_ handle: Handle) {
        #if os(Windows)
        var on: u_long = 1
        _ = ioctlsocket(handle, nonBlockingIO, &on)
        #else
        _ = fcntl(handle, F_SETFL, fcntl(handle, F_GETFL) | O_NONBLOCK)
        #if canImport(Darwin)
        setOption(handle, SOL_SOCKET, SO_NOSIGPIPE, 1)
        #endif
        #endif
    }

    /// The poll event "can be read" (or, for a listening socket, "can accept").
    /// Windows: `POLLRDNORM` (its `POLLIN` adds `POLLRDBAND`, which WSAPoll
    /// does not need here).
    static var readable: Int16 {
        #if os(Windows)
        0x0100
        #else
        Int16(POLLIN)
        #endif
    }

    /// Waits up to `milliseconds` until one of `handles` can be read (or is
    /// closed, or failed). Returns how many can (-1: an error, with its
    /// code) and each one's events, in order.
    static func poll(_ handles: [Handle], milliseconds: Int32) -> (ready: Int32, events: [Int16], error: Int32) {
        #if os(Windows)
        var fds = handles.map { WSAPOLLFD(fd: $0, events: readable, revents: 0) }
        let ready = WSAPoll(&fds, ULONG(fds.count), milliseconds)
        #elseif canImport(Darwin)
        var fds = handles.map { pollfd(fd: $0, events: readable, revents: 0) }
        let ready = Darwin.poll(&fds, nfds_t(fds.count), milliseconds)
        #else
        var fds = handles.map { pollfd(fd: $0, events: readable, revents: 0) }
        let ready = Glibc.poll(&fds, nfds_t(fds.count), milliseconds)
        #endif
        let error = ready < 0 ? lastError : 0
        return (ready, fds.map(\.revents), error)
    }

    /// An error that only means "not now": the call may be tried again.
    static func isTransient(_ code: Int32) -> Bool {
        #if os(Windows)
        code == Int32(WSAEWOULDBLOCK) || code == Int32(WSAEINTR)
        #else
        code == EAGAIN || code == EWOULDBLOCK || code == EINTR
        #endif
    }

    /// Errors that mean the system has no IPv6 loopback, not that the port is taken.
    static func meansNoIPv6(_ code: Int32) -> Bool {
        #if os(Windows)
        code == Int32(WSAEAFNOSUPPORT) || code == Int32(WSAEPFNOSUPPORT) || code == Int32(WSAEPROTONOSUPPORT)
            || code == Int32(WSAEADDRNOTAVAIL)
        #else
        code == EAFNOSUPPORT || code == EPROTONOSUPPORT || code == EADDRNOTAVAIL
        #endif
    }

    /// Reads what has arrived into `buffer`: the byte count, 0 when the peer
    /// closed, -1 on an error (`lastError`; `isTransient` when nothing is there yet).
    static func receive(_ handle: Handle, into buffer: inout [UInt8]) -> Int {
        buffer.withUnsafeMutableBytes { raw in
            #if os(Windows)
            Int(recv(handle, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count), 0))
            #else
            recv(handle, raw.baseAddress, raw.count, 0)
            #endif
        }
    }

    /// Sends what fits of `bytes` (not empty): the count sent, or -1.
    static func send(_ handle: Handle, _ bytes: ArraySlice<UInt8>) -> Int {
        bytes.withUnsafeBytes { raw in
            #if os(Windows)
            Int(WinSDK.send(handle, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count), 0))
            #elseif canImport(Darwin)
            Darwin.send(handle, raw.baseAddress, raw.count, 0)
            #else
            Glibc.send(handle, raw.baseAddress, raw.count, Int32(MSG_NOSIGNAL))
            #endif
        }
    }

    /// Ends a connection after its answer: no more sending (the peer reads
    /// the answer to its end), what the peer still sent is read and dropped
    /// (closing with unread data resets the connection, and a reset can
    /// discard the answer before the browser reads it), then it is closed.
    /// Never waits: the connection does not block.
    static func finish(_ handle: Handle) {
        #if os(Windows)
        _ = shutdown(handle, Int32(SD_SEND))
        #else
        _ = shutdown(handle, Int32(SHUT_WR))
        #endif
        var scratch = [UInt8](repeating: 0, count: 4096)
        var rounds = 0
        while rounds < 16, receive(handle, into: &scratch) > 0 { rounds += 1 }
        close(handle)
    }
}
