import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import ucrt
#endif

/// One line of the MCP server's input.
public enum MCPInputLine: Equatable, Sendable {
    case line(String)
    /// Longer than the reader's limit: consumed to its end, never held in full.
    case tooLong
}

/// Reads stdin for `pimento mcp` line by line without ever holding more than
/// `limit` bytes of a line (plus one read's worth): a line over the limit is
/// skipped to its newline and reported as `.tooLong`. Lines are what
/// `Swift.readLine(strippingNewline: true)` returns: split at "\n", a "\r"
/// before it dropped, invalid UTF-8 repaired, and a last line without a
/// newline still returned.
public final class MCPLineReader: @unchecked Sendable {
    /// Like read(2): fills the buffer with up to `count` bytes and returns how
    /// many; 0 at the end of input, less than 0 on an error (also the end).
    public typealias Read = @Sendable (_ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int

    let limit: Int
    let read: Read
    private var chunk: [UInt8]
    private var position = 0
    private var end = 0
    private var finished = false
    /// The most bytes of one line held at once (tests).
    private(set) var peakLineBytes = 0

    public init(limit: Int, chunkSize: Int = 64 * 1024, read: @escaping Read) {
        self.limit = limit
        self.read = read
        chunk = [UInt8](repeating: 0, count: max(1, chunkSize))
    }

    /// `pimento mcp`'s reader: lines of at most one MCP message.
    public static func mcp(read: @escaping Read) -> MCPLineReader {
        MCPLineReader(limit: MCP.maxMessageBytes, read: read)
    }

    /// The next line; nil at the end of input.
    public func next() -> MCPInputLine? {
        var line: [UInt8] = []
        var tooLong = false
        var sawAny = false
        while true {
            if position < end {
                sawAny = true
                let newline = Self.newline(in: chunk, from: position, to: end)
                let stop = newline ?? end
                if !tooLong {
                    // One byte more than the limit may be a "\r" before the newline.
                    if line.count + (stop - position) > limit + 1 {
                        tooLong = true
                        line = []
                    } else {
                        line.append(contentsOf: chunk[position..<stop])
                        peakLineBytes = max(peakLineBytes, line.count)
                    }
                }
                if let newline {
                    position = newline + 1
                    return finish(line, tooLong: tooLong, newline: true)
                }
                position = end
            }
            if finished { return sawAny ? finish(line, tooLong: tooLong, newline: false) : nil }
            let n = chunk.withUnsafeMutableBytes { read($0.baseAddress!, $0.count) }
            if n <= 0 {
                finished = true
                position = 0
                end = 0
            } else {
                position = 0
                end = min(n, chunk.count)
            }
        }
    }

    /// The index of the first "\n" in `bytes[from..<to]` (memchr: fast also
    /// in debug builds, where a skipped 300 MB line is scanned byte by byte).
    static func newline(in bytes: [UInt8], from: Int, to: Int) -> Int? {
        bytes.withUnsafeBufferPointer { b in
            guard let base = b.baseAddress, to > from,
                  let hit = memchr(base + from, 0x0A, to - from) else { return nil }
            return base.distance(to: UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)))
        }
    }

    private func finish(_ bytes: [UInt8], tooLong: Bool, newline: Bool) -> MCPInputLine {
        if tooLong { return .tooLong }
        var bytes = bytes
        // readLine strips "\n" and "\r\n", not a "\r" at the very end of input.
        if newline, bytes.last == 0x0D { bytes.removeLast() }
        if bytes.count > limit { return .tooLong }
        return .line(String(decoding: bytes, as: UTF8.self))
    }
}
