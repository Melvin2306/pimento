import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

/// An exclusive advisory lock between processes (the app and the CLI) and
/// threads: `flock` on POSIX, `LockFileEx` on Windows, on a small lock file
/// that is never replaced, so the data next to it can be renamed over while
/// the lock is held. Blocks while someone else holds it.
public final class FileLock {
    public struct Failed: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    #if os(Windows)
    private let handle: HANDLE
    #else
    private let fd: Int32
    #endif

    /// Locks `url` (created, mode 600, in a folder created 700 if needed).
    public init(url: URL) throws {
        try PrivateFile.createDirectory(url.deletingLastPathComponent())
        #if os(Windows)
        let path = url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        let opened = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                        DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let opened, opened != INVALID_HANDLE_VALUE else {
            throw Failed(message: "could not open \(path) (Windows error \(GetLastError()))")
        }
        var overlapped = OVERLAPPED()
        if !LockFileEx(opened, DWORD(LOCKFILE_EXCLUSIVE_LOCK), 0, DWORD.max, DWORD.max, &overlapped) {
            let code = GetLastError()
            CloseHandle(opened)
            throw Failed(message: "could not lock \(path) (Windows error \(code))")
        }
        handle = opened
        #else
        let opened = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard opened >= 0 else { throw Failed(message: "could not open \(url.path): \(String(cString: strerror(errno)))") }
        while flock(opened, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let why = String(cString: strerror(errno))
            close(opened)
            throw Failed(message: "could not lock \(url.path): \(why)")
        }
        fd = opened
        #endif
    }

    /// Releases the lock (closing the file releases it too).
    public func unlock() {
        #if os(Windows)
        var overlapped = OVERLAPPED()
        _ = UnlockFileEx(handle, 0, DWORD.max, DWORD.max, &overlapped)
        CloseHandle(handle)
        #else
        _ = flock(fd, LOCK_UN)
        close(fd)
        #endif
    }

    /// `<file>.lock` next to `file`: the lock for read-modify-write of `file`.
    public static func lockURL(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".lock")
    }

    /// Runs `body` holding the lock for `file` (`lockURL(for:)`).
    public static func withLock<T>(for file: URL, _ body: () throws -> T) throws -> T {
        let lock = try FileLock(url: lockURL(for: file))
        defer { lock.unlock() }
        return try body()
    }
}
