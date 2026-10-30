import Foundation

/// The history as CSV (RFC 4180): a header row, CRLF line endings, UTF-8,
/// every field quoted. Times are ISO 8601 UTC, plus one column in local time.
/// Text that a spreadsheet would run as a formula (`=`, `+`, `-`, `@`, tab or
/// CR) gets a `'` in front, at the start of a field and after every `;` or
/// tab in it: a spreadsheet that splits cells on `;` (the list separator of
/// many locales) or tabs still finds no formula there. Most of the text is
/// someone else's (a requester's ticket, a display name).
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

    /// Cell separators other than the comma that a spreadsheet may split on.
    static let otherSeparators: Set<Unicode.Scalar> = [";", "\t"]

    /// One field: formula-guarded at its start and after each `;` or tab,
    /// then quoted.
    public static func field(_ value: String) -> String {
        var guarded = String.UnicodeScalarView()
        var cellStart = true
        for scalar in value.unicodeScalars {
            if cellStart, formulaStarts.contains(scalar) { guarded.append("'") }
            guarded.append(scalar)
            cellStart = otherSeparators.contains(scalar)
        }
        return "\"" + String(guarded).replacingOccurrences(of: "\"", with: "\"\"") + "\""
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
