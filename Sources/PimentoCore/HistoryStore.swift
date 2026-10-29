import Foundation

/// How long records are kept.
public enum HistoryRetention: Int, CaseIterable, Codable, Sendable {
    case days30 = 30
    case days90 = 90
    case days365 = 365
    /// Never pruned (the file still rotates past 5 MB).
    case forever = 0

    public static let `default` = HistoryRetention.days365

    public var title: String {
        switch self {
        case .days30: "30 days"
        case .days90: "90 days"
        case .days365: "1 year"
        case .forever: "Forever"
        }
    }

    /// Records before this are dropped; nil for `forever`.
    public func cutoff(now: Date) -> Date? {
        rawValue > 0 ? now.addingTimeInterval(-TimeInterval(rawValue) * 86400) : nil
    }

    /// The stored number of days, snapped to the nearest option (0 = forever).
    public init(days: Int) {
        if days <= 0 { self = .forever; return }
        self = [Self.days30, .days90, .days365].min { abs($0.rawValue - days) < abs($1.rawValue - days) } ?? .default
    }
}

/// Whether history is kept and for how long. Shared by the app and the CLI
/// through a small file next to the history (`history-settings.json`).
public struct HistorySettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var retention = HistoryRetention.default

    public init(enabled: Bool = true, retention: HistoryRetention = .default) {
        self.enabled = enabled
        self.retention = retention
    }

    enum CodingKeys: String, CodingKey { case enabled, retentionDays }

    /// Lenient: anything missing or unreadable keeps its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        retention = ((try? c.decodeIfPresent(Int.self, forKey: .retentionDays)) ?? nil).map(HistoryRetention.init(days:)) ?? .default
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(retention.rawValue, forKey: .retentionDays)
    }
}

public enum HistoryError: Error, LocalizedError, Equatable {
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .io(let why): "Could not write the history file: \(why)"
        }
    }
}

/// What reading the history found.
public struct HistoryLoad: Equatable, Sendable {
    /// In file order (oldest first, the rotated file before the current one).
    public var records: [HistoryRecord]
    /// Lines that are not a record (cut off, or not JSON); skipped.
    public var unreadableLines: Int

    public init(records: [HistoryRecord] = [], unreadableLines: Int = 0) {
        self.records = records
        self.unreadableLines = unreadableLines
    }
}

/// The history file, shared by the app and the CLI: `history.jsonl` in
/// `PimentoPaths.dataDirectory` (`~/Library/Application Support/Pimento` on
/// macOS), or `$PIMENTO_HISTORY`.
///
/// Append-only JSON Lines, mode 600. Every append takes an exclusive lock
/// (`flock` on the file; on Windows `LockFileEx` on `history.jsonl.lock`) and
/// writes each record with one write on an append-only descriptor, so the app
/// and the CLI can write at the same time without interleaving. Past
/// `maxBytes` the file becomes `history.1.jsonl` (replacing an older one) and
/// a new file starts. (The plumbing is in HistoryFile.swift, per platform.)
public struct HistoryStore: Sendable {
    public static let environmentVariable = "PIMENTO_HISTORY"
    /// About 8,000 records.
    public static let defaultMaxBytes = 5 * 1024 * 1024

    public let url: URL
    public let maxBytes: Int

    public init(url: URL, maxBytes: Int = HistoryStore.defaultMaxBytes) {
        self.url = url
        self.maxBytes = maxBytes
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(url: Self.location(environment: environment))
    }

    public static func location(
        environment: [String: String], home: String = NSHomeDirectory(), platform: HostPlatform = .current
    ) -> URL {
        if let custom = PimentoPaths.nonEmpty(environment[environmentVariable]) {
            return URL(fileURLWithPath: PimentoPaths.expandTilde(custom, home: home, platform: platform))
        }
        return URL(fileURLWithPath: platform.join(
            PimentoPaths.dataDirectoryPath(environment: environment, home: home, platform: platform), "history.jsonl"))
    }

    /// `history.1.jsonl`: the previous file after a rotation.
    public var rotatedURL: URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "jsonl" : url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent("\(base).1.\(ext)")
    }

    /// `history-settings.json`, next to the history.
    public var settingsURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-settings.json")
    }

    // MARK: Settings

    public func loadSettings() -> HistorySettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(HistorySettings.self, from: data) else { return HistorySettings() }
        return settings
    }

    public func saveSettings(_ settings: HistorySettings) throws {
        try createDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(settings).write(to: settingsURL, options: .atomic)
            PrivateFile.restrict(settingsURL)
        } catch {
            throw HistoryError.io(error.localizedDescription)
        }
    }

    // MARK: Reading

    /// Both files, oldest first. A missing file is an empty history.
    public func load() -> HistoryLoad {
        var result = HistoryLoad()
        for file in [rotatedURL, url] {
            guard let data = try? Data(contentsOf: file) else { continue }
            let part = Self.decode(data)
            result.records += part.records
            result.unreadableLines += part.unreadableLines
        }
        return result
    }

    /// The records in JSON Lines `data`; blank lines are ignored.
    public static func decode(_ data: Data) -> HistoryLoad {
        let decoder = JSONDecoder()
        var result = HistoryLoad()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let trimmed = line.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
            guard !trimmed.isEmpty else { continue }
            if let record = try? decoder.decode(HistoryRecord.self, from: Data(trimmed)) {
                result.records.append(record)
            } else {
                result.unreadableLines += 1
            }
        }
        return result
    }

    /// The history as shown: within `settings`' retention, newest first,
    /// tenant names filled in from other records.
    public func records(settings: HistorySettings? = nil, now: Date = Date(), knownTenants: [String: String] = [:]) -> [HistoryRecord] {
        let cutoff = (settings ?? loadSettings()).retention.cutoff(now: now)
        let kept = load().records.filter { cutoff == nil || $0.at >= cutoff! }
        return HistoryLog.newestFirst(HistoryLog.fillingTenantLabels(kept, known: knownTenants))
    }

    // MARK: Writing

    /// Appends `records`, one line each.
    public func append(_ records: [HistoryRecord]) throws {
        guard !records.isEmpty else { return }
        let lines = try records.map { try $0.jsonLine() + Data([0x0A]) }
        try withLockedFile { write in
            for line in lines { try write(line) }
        }
    }

    /// Appends the records whose request id is not in the history yet (Azure
    /// imports). Returns how many were added and how many were known.
    @discardableResult
    public func importRecords(_ records: [HistoryRecord]) throws -> (added: Int, known: Int) {
        var added = 0, known = 0
        try withLockedFile { write in
            var seen = Set(load().records.flatMap(\.requestIds))
            for record in records {
                let ids = record.requestIds
                if ids.isEmpty || ids.contains(where: seen.contains) {
                    known += 1
                    continue
                }
                try write(try record.jsonLine() + Data([0x0A]))
                seen.formUnion(ids)
                added += 1
            }
        }
        return (added, known)
    }

    /// Drops records older than the retention. Returns how many were removed.
    /// Lines it cannot read (a newer format, a hand edit) are kept: their age
    /// is unknown, and `load()` reports them as unreadable.
    @discardableResult
    public func prune(retention: HistoryRetention, now: Date = Date()) throws -> Int {
        guard let cutoff = retention.cutoff(now: now) else { return 0 }
        guard FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: rotatedURL.path) else { return 0 }
        var removed = 0
        try withLockedFile { _ in
            for file in [rotatedURL, url] {
                guard let data = try? Data(contentsOf: file) else { continue }
                var kept = Data()
                var dropped = 0
                let decoder = JSONDecoder()
                for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    if let r = try? decoder.decode(HistoryRecord.self, from: Data(line)), r.at < cutoff {
                        dropped += 1
                    } else {
                        kept.append(contentsOf: line)
                        kept.append(0x0A)
                    }
                }
                guard dropped > 0 else { continue }
                removed += dropped
                if kept.isEmpty, file == rotatedURL {
                    try? FileManager.default.removeItem(at: file)
                } else {
                    try replace(file, with: kept)
                }
            }
        }
        return removed
    }

    /// Removes every record (both files). The settings stay.
    public func clear() throws {
        try withLockedFile { _ in
            try? FileManager.default.removeItem(at: rotatedURL)
            try replace(url, with: Data())
        }
    }

    // MARK: File plumbing

    func createDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw HistoryError.io(error.localizedDescription)
        }
    }
}

/// Writes the records of one app or CLI process. Never throws: a history that
/// cannot be written must not fail an activation (`lastError` says why).
public final class HistoryRecorder: @unchecked Sendable {
    public let store: HistoryStore
    public let source: HistorySource
    public let version: String
    let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var labels: [String: String] = [:]
    private var pruned = false
    private var error: String?

    public init(store: HistoryStore, source: HistorySource, version: String = AppInfo.version,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.source = source
        self.version = version
        self.clock = clock
    }

    /// Names of the tenants the app knows, by tenant GUID.
    public func setTenantLabels(_ labels: [String: String]) {
        lock.withLock { self.labels = Dictionary(labels.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a }) }
    }

    /// The last write error, if any.
    public var lastError: String? { lock.withLock { error } }

    /// The context of records written now for `tenantId`.
    public func context(tenantId: String?) -> HistoryContext {
        let label = tenantId.flatMap { id in lock.withLock { labels[id.lowercased()] } }
        return HistoryContext(tenantId: tenantId, tenantLabel: label, source: source, version: version, at: clock())
    }

    /// Appends `records` when history is on; prunes old records once per process.
    public func record(_ records: [HistoryRecord]) {
        guard !records.isEmpty else { return }
        let settings = store.loadSettings()
        guard settings.enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            try store.append(records)
            if !pruned {
                pruned = true
                try store.prune(retention: settings.retention, now: clock())
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
