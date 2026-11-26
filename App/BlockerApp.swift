import BackgroundTasks
import SwiftUI

@main
struct BlockerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(FilterStore.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundRefresh.schedule() }
        }
        // iOS decides when this actually runs (usually overnight, on Wi-Fi and power).
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            BackgroundRefresh.schedule()
            await FilterStore.shared.updateFilters()
        }
    }
}

enum BackgroundRefresh {
    /// Must match BGTaskSchedulerPermittedIdentifiers in Config/App-Info.plist.
    static let identifier = (Bundle.main.bundleIdentifier ?? "blocker") + ".refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
