import Foundation

/// `pimento history`: the local log of every write Pimento sent (app and
/// CLI), listed, exported as CSV, filled from Azure, or cleared.
extension CLIRunner {
    /// The table shows this many records unless `--limit` says otherwise.
    static let historyTableLimit = 50

    func history(_ command: HistoryCommand) async throws -> CLIExit {
        guard let store = env.history else {
            err(errStyle.red("error:") + " no history file is configured.")
            return .failure
        }
        switch command {
        case .list(let o): return try historyList(o, store: store)
        case .export(let file, let o): return try historyExport(file: file, o, store: store)
        case .importAzure(let o): return try await historyImport(o, store: store)
        case .clear(let yes): return try historyClear(assumeYes: yes, store: store)
        }
    }

    /// The filter of `o`, with `--since` / `--until` read against the clock.
    func historyFilter(_ o: HistoryListOptions) throws -> HistoryFilter {
        func date(_ raw: String?, flag: String) throws -> Date? {
            guard let raw else { return nil }
            guard let d = HistoryDate.parse(raw, now: env.now(), timeZone: env.timeZone, endOfDay: flag == "--until") else {
                throw CLIParseError.invalidDate(flag: flag, value: raw)
            }
            return d
        }
        return HistoryFilter(
            since: try date(o.since, flag: "--since"), until: try date(o.until, flag: "--until"),
            actions: Set(o.actions), results: Set(o.results), tenant: o.tenant, text: o.text.joined(separator: " "))
    }

    func historyList(_ o: HistoryListOptions, store: HistoryStore) throws -> CLIExit {
        let filter = try historyFilter(o)
        let all = store.records(now: env.now())
        let limit = o.limit ?? (o.json || o.csv ? nil : Self.historyTableLimit)
        let matching = filter.apply(all)
        let shown = limit.map { Array(matching.prefix($0)) } ?? matching
        if o.json {
            out(CLIJSON.encode(CLIJSON.History(records: shown, total: matching.count, file: store.url.path)))
            return .success
        }
        if o.csv {
            env.write(HistoryCSV.encode(shown, timeZone: env.timeZone), .out)
            return .success
        }
        guard !shown.isEmpty else {
            err(all.isEmpty ? "No history yet. Activations, renewals, cancellations and approvals made with Pimento are recorded in \(store.url.path)."
                : "No history entries match.")
            if !store.loadSettings().enabled { err(errStyle.yellow("note:") + " recording is turned off (Settings › History in the app).") }
            return .success
        }
        historyTable(shown).render(style: outStyle, maxWidth: env.terminalWidth).forEach { out($0) }
        if matching.count > shown.count {
            err(errStyle.dim("Showing the newest \(shown.count) of \(matching.count); use --limit N or --since."))
        }
        if !store.loadSettings().enabled { err(errStyle.yellow("note:") + " recording is turned off (Settings › History in the app).") }
        return .success
    }

    func historyTable(_ records: [HistoryRecord]) -> TextTable {
        let now = env.now()
        let showTenant = Set(records.compactMap { $0.tenantId?.lowercased() }).count > 1
        var headers = ["WHEN", "ACTION", "RESULT", "ROLE", "RESOURCE"]
        if showTenant { headers.append("TENANT") }
        headers += ["DURATION", "SOURCE", "REQUEST"]
        var table = TextTable(headers: headers, flexible: showTenant ? [3, 4, 5] : [3, 4])
        for r in records {
            var row: [TextTable.Cell] = [
                .init("\(CLIFormat.clock(r.at, now: now, timeZone: env.timeZone)) (\(CLIFormat.ago(r.at, now: now)))", .dim),
                .init(r.action.rawValue),
                .init(r.result.rawValue, Self.tone(r.result)),
                .init(r.roleDisplay, r.isOwner ? .strong : .plain),
                .init(r.scopeDisplay),
            ]
            if showTenant { row.append(.init(r.tenantDisplay, .dim)) }
            row += [
                .init(r.durationText ?? "", .dim),
                .init(r.source.rawValue, .dim),
                .init(r.shortRequestId ?? "", .dim),
            ]
            table.append(row)
        }
        return table
    }

    static func tone(_ result: HistoryResult) -> TextTable.Tone {
        switch result {
        case .succeeded: .good
        case .pending: .warn
        case .failed, .denied, .expired: .bad
        default: .dim
        }
    }

    func historyExport(file: String, _ o: HistoryListOptions, store: HistoryStore) throws -> CLIExit {
        let filter = try historyFilter(o)
        let matching = filter.apply(store.records(now: env.now()))
        let records = o.limit.map { Array(matching.prefix($0)) } ?? matching
        if file == "-" {
            env.write(HistoryCSV.encode(records, timeZone: env.timeZone), .out)
            return .success
        }
        let url = URL(fileURLWithPath: PimentoPaths.expandTilde(file))
        do {
            try HistoryCSV.write(records, to: url, timeZone: env.timeZone)
        } catch {
            err(errStyle.red("error:") + " " + error.localizedDescription)
            return .failure
        }
        err("Exported \(CLIFormat.plural(records.count, "record")) to \(url.path).")
        return .success
    }

    func historyImport(_ o: HistoryImportOptions, store: HistoryStore) async throws -> CLIExit {
        let since: Date?
        if let raw = o.since {
            guard let d = HistoryDate.parse(raw, now: env.now(), timeZone: env.timeZone) else {
                throw CLIParseError.invalidDate(flag: "--since", value: raw)
            }
            since = d
        } else {
            since = nil
        }
        let tenant = try resolveTenant(o.tenant)
        // Read-only: a GET-only transport, and nothing recorded for the read itself.
        let service = makeService(tenant.tenantId, true)
        let records: [HistoryRecord]
        do { records = try await service.loadHistoryFromAzure(since: since, now: env.now()) } catch {
            return report(error, tenant: tenant.tenantId)
        }
        let settings = store.loadSettings()
        let cutoff = settings.retention.cutoff(now: env.now())
        let kept = records.filter { cutoff == nil || $0.at >= cutoff! }
        let result: (added: Int, known: Int)
        do { result = try store.importRecords(kept) } catch {
            err(errStyle.red("error:") + " " + error.localizedDescription)
            return .failure
        }
        if o.json {
            out(CLIJSON.encode(CLIJSON.HistoryImport(read: records.count, added: result.added, known: result.known,
                                                    olderThanRetention: records.count - kept.count, file: store.url.path)))
        } else {
            var line = "Read \(CLIFormat.plural(records.count, "request")) from Azure: \(result.added) added, \(result.known) already in the history"
            if records.count > kept.count { line += ", \(records.count - kept.count) older than the retention (\(settings.retention.title))" }
            err(line + ".")
        }
        return .success
    }

    func historyClear(assumeYes: Bool, store: HistoryStore) throws -> CLIExit {
        let count = store.load().records.count
        let policy = ConfirmationPolicy.decide(dryRun: false, assumeYes: assumeYes, interactive: env.stdinIsTTY)
        if policy == .refuse { throw CLIParseError.clearNeedsConfirmation }
        if policy == .ask {
            env.write("Delete all \(CLIFormat.plural(count, "history record")) in \(store.url.path)? [y/N] ", .err)
            guard ConfirmationPolicy.isYes(env.readLine()) else {
                err("Cancelled. Nothing was deleted.")
                return .failure
            }
        }
        do { try store.clear() } catch {
            err(errStyle.red("error:") + " " + error.localizedDescription)
            return .failure
        }
        err("Deleted \(CLIFormat.plural(count, "history record")).")
        return .success
    }
}

extension CLIFormat {
    /// `<1m`, `45m`, `3h`, `2d`, `5w` since `date`.
    public static func ago(_ date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return s < 0 ? "in the future" : "<1m ago" }
        let m = s / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 48 { return "\(h)h ago" }
        let d = h / 24
        if d < 14 { return "\(d)d ago" }
        return "\(d / 7)w ago"
    }
}

extension CLIJSON {
    /// `pimento history --json`.
    public struct History: Encodable, Sendable {
        public let records: [HistoryRecord]
        /// Matching records before `--limit`.
        public let total: Int
        public let file: String
    }

    /// `pimento history import-azure --json`.
    public struct HistoryImport: Encodable, Equatable, Sendable {
        public let read: Int
        public let added: Int
        public let known: Int
        public let olderThanRetention: Int
        public let file: String
    }
}
