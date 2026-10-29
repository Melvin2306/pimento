import Foundation
import Testing

/// Checks on the app's SwiftUI sources that the compiler cannot make. The app
/// target has no test target, so these read the files.
@Suite struct AppSourceTests {
    static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/PimentoApp")

    static func sources() throws -> [(name: String, text: String)] {
        let files = try FileManager.default.contentsOfDirectory(at: appSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Views whose body reads `AppModel` from the environment.
    static func environmentReaders(in sources: [(name: String, text: String)]) -> Set<String> {
        var names = Set<String>()
        for (_, text) in sources {
            var current: String?
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let range = trimmed.range(of: #"^(private |fileprivate )?struct (\w+)"#, options: .regularExpression) {
                    current = trimmed[range].components(separatedBy: " ").last
                }
                if trimmed.hasPrefix("@Environment(AppModel.self)"), let current { names.insert(current) }
            }
        }
        return names
    }

    /// The text of every `Table(…) { … }` call: from `Table(` to the brace closing its columns.
    static func tableBodies(_ text: String) -> [Substring] {
        var bodies: [Substring] = []
        var search = text.startIndex
        while let start = text.range(of: "Table(", range: search..<text.endIndex) {
            guard let open = text.range(of: "{", range: start.upperBound..<text.endIndex) else { break }
            var depth = 0
            var index = open.lowerBound
            while index < text.endIndex {
                if text[index] == "{" { depth += 1 }
                if text[index] == "}" { depth -= 1; if depth == 0 { break } }
                index = text.index(after: index)
            }
            bodies.append(text[start.lowerBound..<index])
            search = index < text.endIndex ? text.index(after: index) : text.endIndex
        }
        return bodies
    }

    /// Regression: `DurationCell` read `AppModel` from the environment and
    /// trapped ("No Observable object of type AppModel found") when filtering
    /// removed rows: SwiftUI can update a cell that has left the table without
    /// the window's environment. Table cells get the model as a value.
    @Test func tableCellsDoNotReadTheModelFromTheEnvironment() throws {
        let sources = try Self.sources()
        let readers = Self.environmentReaders(in: sources)
        #expect(readers.contains("RoleTable"), "the scan finds environment readers")
        #expect(!readers.contains("DurationCell"))
        var tables = 0
        for (name, text) in sources {
            for body in Self.tableBodies(text) {
                tables += 1
                for reader in readers {
                    #expect(body.range(of: #"\b\#(reader)\("#, options: .regularExpression) == nil,
                            "\(name): \(reader) reads AppModel from the environment but is used in a Table cell")
                }
            }
        }
        #expect(tables >= 2, "RoleTable and HistoryTable")
    }
}
