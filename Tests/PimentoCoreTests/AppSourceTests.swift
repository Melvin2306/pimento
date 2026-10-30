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

    /// The menu bar extra's window is not one of the app's windows and updates
    /// on its own schedule: its views get the model as a value (like table
    /// cells), and the scene still injects it for anything below.
    @Test func menuBarViewsGetTheModelAsAValue() throws {
        let sources = try Self.sources()
        let readers = Self.environmentReaders(in: sources)
        let menuBar = try #require(sources.first { $0.name == "MenuBarViews.swift" }).text
        var views: [String] = []
        for line in menuBar.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: #"^(private |fileprivate )?struct (\w+)"#, options: .regularExpression) {
                views.append(trimmed[range].components(separatedBy: " ").last ?? "")
            }
        }
        #expect(views.contains("MenuBarContent") && views.contains("MenuBarLabel"), "the scan finds the menu bar views")
        for view in views {
            #expect(!readers.contains(view), "\(view) reads AppModel from the environment")
        }
        let main = try #require(sources.first { $0.name == "main.swift" }).text
        let scene = try #require(main.range(of: "MenuBarExtra(")).lowerBound
        #expect(main[scene...].contains(".environment(model)"), "the menu bar extra's content gets the model in its environment")
    }

    /// Regression: `activate()` and `renew()` set `isActivating` only after
    /// loading the policies (seconds), so a second click, ⌘↩ or preset sent
    /// the same PUTs twice. Busy must be set before the first `await`.
    @Test func writesAreMarkedBusyBeforeTheirFirstAwait() throws {
        let model = try String(contentsOf: Self.appSources.appendingPathComponent("AppModel.swift"), encoding: .utf8)
        for signature in ["func activate() async {", "func renew(_ targets: [EligibleRole]", "func deactivate(_ targets: [EligibleRole]) async {"] {
            guard let start = model.range(of: signature) else {
                Issue.record("\(signature) not found")
                continue
            }
            // The code after the signature, without `//` comments.
            let body = model[start.upperBound...].components(separatedBy: "\n")
                .map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
            let busy = try #require(body.range(of: "isActivating = true"), "\(signature) sets isActivating")
            let firstAwait = try #require(body.range(of: "await "), "\(signature) awaits")
            #expect(busy.lowerBound < firstAwait.lowerBound, "\(signature) is busy before its first await")
        }
    }

    /// Regression: the notification delegate was installed in a Task after
    /// `applicationDidFinishLaunching`, too late for the reminder action
    /// (Renew / End Now) that launched the app.
    @Test func notificationDelegateIsSetBeforeLaunchFinishes() throws {
        let main = try String(contentsOf: Self.appSources.appendingPathComponent("main.swift"), encoding: .utf8)
        let willFinish = try #require(main.range(of: "func applicationWillFinishLaunching"))
        let didFinish = try #require(main.range(of: "func applicationDidFinishLaunching"))
        let setUp = try #require(main.range(of: "Notifier.setUp()"))
        #expect(willFinish.lowerBound < setUp.lowerBound && setUp.lowerBound < didFinish.lowerBound)
        #expect(!main.contains("Task { @MainActor in Notifier.setUp() }"))
    }

    /// Expiry-reminder actions write to Azure as the user: macOS must ask to
    /// unlock before running them from the lock screen, and End Now on an
    /// Owner role goes through the app's confirmation, as in the app.
    @Test func reminderActionsNeedAnUnlockedMacAndOwnersAreConfirmed() throws {
        let notifier = try String(contentsOf: Self.appSources.appendingPathComponent("Notifier.swift"), encoding: .utf8)
        let category = try #require(notifier.range(of: "reminderCategory: UNNotificationCategory"))
        let body = notifier[category.upperBound...].prefix(700)
        #expect(body.contains("if action.requiresAuthentication { options.insert(.authenticationRequired) }"))
        #expect(body.contains("options.insert(.destructive)"))

        let model = try String(contentsOf: Self.appSources.appendingPathComponent("AppModel.swift"), encoding: .utf8)
        let handler = try #require(model.range(of: "func handleReminderAction("))
        let end = try #require(model.range(of: "case .end:", range: handler.upperBound..<model.endIndex))
        let endBody = model[end.upperBound...].prefix(400)
        let owners = try #require(endBody.range(of: "targets.contains(where: \\.isOwner) && prefs.confirmOwnerRoles"))
        let ask = try #require(endBody.range(of: "requestDeactivation(targets)"))
        let send = try #require(endBody.range(of: "await deactivate(targets)"))
        #expect(owners.lowerBound < ask.lowerBound && ask.lowerBound < send.lowerBound)
    }

    /// The app's reads and previews (roles, policies, requests, approvals,
    /// Azure history) go through `service.readOnly`, a GET-only transport;
    /// only the functions that write use the writable service.
    @Test func appReadsAndPreviewsAreReadOnly() throws {
        let model = try String(contentsOf: Self.appSources.appendingPathComponent("AppModel.swift"), encoding: .utf8)
        for read in ["loadRequestHistory()", "loadApprovalInbox()", "loadPolicies(", "loadRoles()", "loadHistoryFromAzure(", "review(approvalId:"] {
            var search = model.startIndex..<model.endIndex
            while let hit = model.range(of: "service." + read, range: search) {
                // The `service` in scope: a local `let service = service.readOnly`, or `service.readOnly.` itself.
                let before = model[..<hit.lowerBound]
                let direct = before.hasSuffix("readOnly.") || model[hit.lowerBound...].hasPrefix("service.readOnly")
                let local = before.range(of: "let service = service", options: .backwards).map {
                    model[$0.upperBound...].hasPrefix(".readOnly")
                } ?? false
                #expect(direct || local, "\(read) through a writable service")
                search = hit.upperBound..<model.endIndex
            }
        }
        #expect(model.components(separatedBy: "let service = service.readOnly").count - 1 == 6)
    }
}
