import Foundation

/// The history as CSV (RFC 4180): a header row, CRLF line endings, UTF-8,
/// fields quoted when they hold a comma, quote or line break. Times are ISO
/// 8601 UTC, plus one column in local time. Text that a spreadsheet would run
/// as a formula (starting with `=`, `+`, `-`, `@`, tab or CR) gets a leading
/// `'`, so a justification cannot become a formula when the file is opened.
public enum HistoryCSV {
    public static let columns = [
        "timestamp_utc", "local_time", "action", "result", "status", "message", "tenant_id", "tenant", "role", "resource",
        "scope", "requested_duration", "duration_minutes", "start_utc", "end_utc", "justification", "ticket_number",
        "ticket_system", "request_id", "requester", "source", "pimento_version",
    ]

    public static func encode(_ records: [HistoryRecord], timeZone: TimeZone = .current) -> String {
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        local.dateFormat = "yyyy-MM-dd HH:mm:ss xxx"
        var lines = [columns.map(field).joined(separator: ",")]
        for r in records {
            let values: [String?] = [
                AzureDate.format(r.at), local.string(from: r.at), r.action.rawValue, r.result.rawValue, r.status, r.message,
                r.tenantId, r.tenantLabel, r.roleName, r.scopeName, r.scope, r.requestedDuration, r.durationMinutes.map(String.init),
                r.start.map(AzureDate.format), r.end.map(AzureDate.format), r.justification, r.ticketNumber, r.ticketSystem,
                r.requestId, r.requester, r.source.rawValue, r.version,
            ]
            lines.append(values.map { field($0 ?? "") }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public static func data(_ records: [HistoryRecord], timeZone: TimeZone = .current) -> Data {
        Data(encode(records, timeZone: timeZone).utf8)
    }

    /// Characters a spreadsheet reads as the start of a formula.
    /// (Unicode scalars: `"\r\n"` is a single `Character`.)
    static let formulaStarts: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]

    /// One field: formula-guarded, then quoted if needed.
    public static func field(_ value: String) -> String {
        var s = value
        if let first = s.unicodeScalars.first, formulaStarts.contains(first) { s = "'" + s }
        guard s.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Writes the CSV to `url`, readable only by you (it holds justifications).
    public static func write(_ records: [HistoryRecord], to url: URL, timeZone: TimeZone = .current) throws {
        do {
            // Mode 600 from creation, not chmod-ed after an umask-mode write.
            try PrivateFile.write(data(records, timeZone: timeZone), to: url)
        } catch {
            throw HistoryError.io(error.localizedDescription)
        }
    }
}
