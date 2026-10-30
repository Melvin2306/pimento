import Foundation
import Testing

/// Demo mode's isolation in the app, checked on its sources (the app target
/// has no test target): settings, time and notifications go through the
/// demo-aware runtime.
@Suite struct DemoAppSourceTests {
    static func source(_ name: String) throws -> String {
        try String(contentsOf: AppSourceTests.appSources.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func settingsAreReadAndWrittenThroughTheRuntimesDefaults() throws {
        for (name, text) in try AppSourceTests.sources() where name != "DemoSupport.swift" {
            #expect(!text.contains("UserDefaults.standard"), "\(name) uses UserDefaults.standard; use AppRuntime.defaults")
            for line in text.components(separatedBy: "\n") where line.contains("@AppStorage(") {
                #expect(line.contains("store: AppRuntime.defaults"), "\(name): \(line)")
            }
        }
    }

    @Test func theDemoFilesStoresAndServicesAreUsedInDemoMode() throws {
        let model = try Self.source("AppModel.swift")
        #expect(model.contains("AppRuntime.demo?.workspace.presetStore ?? PresetStore()"))
        #expect(model.contains("AppRuntime.demo?.workspace.historyStore ?? HistoryStore()"))
        #expect(model.contains("AppRuntime.demo?.workspace.authSettingsStore ?? AuthSettingsStore()"))
        #expect(model.contains("demo.makeBroker()"))
        // Every service is built by the one factory that knows the demo.
        #expect(!model.contains("= PIMService("))
        #expect(!model.contains("TenantDirectory.load(") || model.contains("case _ where AppRuntime.demo != nil"))
        let main = try Self.source("main.swift")
        #expect(main.contains("AppRuntime.configure("))
        #expect(main.range(of: "AppRuntime.configure(")!.lowerBound < main.range(of: "PimentoApp.main()")!.lowerBound)
    }

    @Test func timeComesFromTheAppClock() throws {
        for name in ["AppModel.swift", "ContentView.swift", "MenuBarViews.swift", "ApprovalViews.swift", "ScheduleViews.swift", "Notifier.swift"] {
            let text = try Self.source(name)
            #expect(text.range(of: #"(?<![A-Za-z])Date\(\)"#, options: .regularExpression) == nil,
                    "\(name) reads the real time; use AppClock.now()")
            if name.hasSuffix("Views.swift") && name != "MenuBarViews.swift" || name == "Notifier.swift" {
                #expect(!text.contains(".timeIntervalSinceNow"), "\(name) measures against the real time")
            }
        }
    }

    @Test func notificationsAreTaggedAndFilteredByMode() throws {
        let notifier = try Self.source("Notifier.swift")
        #expect(notifier.contains("DemoNotifications.tagged(request.content)"))
        #expect(notifier.contains("guard DemoNotifications.isOwn(response.notification.request.content)"))
        #expect(notifier.components(separatedBy: "DemoNotifications.isOwn(").count - 1 >= 6)
    }
}
