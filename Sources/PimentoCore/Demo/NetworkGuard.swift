import Foundation

/// Demo mode's promise that nothing leaves the machine: while a monitor is
/// set (for the process in the demo app and CLI, or for a task in tests),
/// `URLSessionTransport`, the Azure CLI, the sign-in listener and the
/// browser openers (`BrowserLaunch`) refuse to start, and the attempt is
/// recorded.
public enum NetworkGuard {
    public final class Monitor: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts: [String] = []

        public init() {}

        /// What tried to reach the network (empty: nothing did).
        public var blocked: [String] { lock.withLock { attempts } }

        func record(_ what: String) { lock.withLock { attempts.append(what) } }
    }

    public struct Blocked: Error, LocalizedError, Equatable {
        public let what: String
        public var errorDescription: String? { "Demo mode is offline: refused \(what)." }
    }

    /// The monitor of the current task (tests).
    @TaskLocal public static var monitor: Monitor?

    private static let processLock = NSLock()
    nonisolated(unsafe) private static var processMonitor: Monitor?

    /// Blocks the network for the rest of the process (demo app and CLI).
    public static func blockForProcess(_ monitor: Monitor = Monitor()) {
        processLock.withLock { processMonitor = monitor }
    }

    /// The process-wide monitor, if the network is blocked for the process.
    public static var processWide: Monitor? { processLock.withLock { processMonitor } }

    /// False (and records `what`) while a monitor is set.
    public static func allows(_ what: @autoclosure () -> String) -> Bool {
        (try? check(what())) != nil
    }

    /// Throws `Blocked` (and records `what`) while a monitor is set.
    public static func check(_ what: @autoclosure () -> String) throws {
        guard let monitor = monitor ?? processWide else { return }
        let text = what()
        monitor.record(text)
        throw Blocked(what: text)
    }
}
