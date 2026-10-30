import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

// The history file's locking and atomic replacement, per platform.

#if !os(Windows)
extension HistoryStore {
    /// Runs `body` with the history file open for appending and exclusively
    /// locked. Rotates first when the file has grown past `maxBytes`. A file
    /// replaced while waiting for the lock (another writer rotated, pruned or
    /// cleared it) is opened again.
    func withLockedFile(_ body: (_ write: (Data) throws -> Void) throws -> Void) throws {
        try createDirectory()
        for _ in 0..<8 {
            // Never through a symbolic link: the history is Pimento's own file.
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else {
                throw HistoryError.io(errno == ELOOP ? "\(url.path) is a symbolic link; Pimento does not write through it"
                                                     : String(cString: strerror(errno)))
            }
            defer { close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw HistoryError.io(String(cString: strerror(errno))) }
            var held = stat(), current = stat()
            guard fstat(fd, &held) == 0 else { throw HistoryError.io(String(cString: strerror(errno))) }
            guard held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw HistoryError.io("\(url.path) is not a regular file") }
            // lstat: the name must still be this very file, not a link to it.
            guard lstat(url.path, &current) == 0, current.st_ino == held.st_ino, current.st_dev == held.st_dev else { continue }
            _ = fchmod(fd, 0o600)
            if held.st_size > off_t(maxBytes) {
                _ = rename(url.path, rotatedURL.path)
                continue
            }
            // A line cut off by a crash must not swallow the next record.
            if held.st_size > 0 {
                let reader = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                if reader >= 0 {
                    var last: UInt8 = 0
                    if pread(reader, &last, 1, held.st_size - 1) == 1, last != 0x0A { try Self.writeAll(fd, Data([0x0A])) }
                    close(reader)
                }
            }
            try body { try Self.writeAll(fd, $0) }
            return
        }
        throw HistoryError.io("the file kept changing while waiting for it")
    }

    /// Replaces `file` atomically (write a temporary file, rename it over).
    /// Called with the lock held.
    func replace(_ file: URL, with data: Data) throws {
        let temp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HistoryError.io(String(cString: strerror(errno))) }
        do {
            try Self.writeAll(fd, data)
            close(fd)
        } catch {
            close(fd)
            unlink(temp.path)
            throw error
        }
        guard rename(temp.path, file.path) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(temp.path)
            throw HistoryError.io(why)
        }
    }

    /// `write(2)` until all of `data` is written (one call for a line in practice).
    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var p = buffer.baseAddress else { return }
            var left = buffer.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw HistoryError.io(String(cString: strerror(errno)))
                }
                left -= n
                p += n
            }
        }
    }
}

#else
extension HistoryStore {
    /// `history.jsonl.lock`: Windows locks a separate file, which is never
    /// replaced, so the history itself can be renamed and replaced under it.
    var lockURL: URL { FileLock.lockURL(for: url) }

    /// Runs `body` with the history exclusively locked (`LockFileEx` on
    /// `lockURL`). Rotates first when the file has grown past `maxBytes`. The
    /// file is opened for appending on the first write only, so `body` can
    /// replace it (prune, clear) while no handle is open on it.
    func withLockedFile(_ body: (_ write: (Data) throws -> Void) throws -> Void) throws {
        try createDirectory()
        let lock: FileLock
        do { lock = try FileLock(url: lockURL) } catch { throw HistoryError.io(error.localizedDescription) }
        defer { lock.unlock() }
        let files = FileManager.default
        let size = ((try? files.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        if size > maxBytes {
            do {
                if files.fileExists(atPath: rotatedURL.path) { try files.removeItem(at: rotatedURL) }
                try files.moveItem(at: url, to: rotatedURL)
            } catch {
                throw HistoryError.io(error.localizedDescription)
            }
        }
        var handle: FileHandle?
        defer { try? handle?.close() }
        func append(_ data: Data) throws {
            do {
                if handle == nil {
                    // Never through a symbolic link (reparse point): the history is Pimento's own file.
                    if (try? files.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink {
                        throw HistoryError.io("\(url.path) is a symbolic link; Pimento does not write through it")
                    }
                    if !files.fileExists(atPath: url.path), !files.createFile(atPath: url.path, contents: nil) {
                        throw HistoryError.io("could not create \(url.path)")
                    }
                    let opened = try FileHandle(forWritingTo: url)
                    handle = opened
                    let end = try opened.seekToEnd()
                    // A line cut off by a crash must not swallow the next record.
                    if end > 0 {
                        let reader = try FileHandle(forReadingFrom: url)
                        try reader.seek(toOffset: end - 1)
                        let last = try reader.read(upToCount: 1)
                        try reader.close()
                        if last != Data([0x0A]) { try opened.write(contentsOf: Data([0x0A])) }
                    }
                }
                try handle?.write(contentsOf: data)
            } catch let error as HistoryError {
                throw error
            } catch {
                throw HistoryError.io(error.localizedDescription)
            }
        }
        try body(append)
    }

    /// Replaces `file` atomically. Called with the lock held.
    func replace(_ file: URL, with data: Data) throws {
        do { try data.write(to: file, options: .atomic) } catch { throw HistoryError.io(error.localizedDescription) }
    }
}

#endif
