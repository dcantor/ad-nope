import SwiftUI
#if os(iOS)
import BackgroundTasks
#endif

@main
struct BlockerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        #if os(iOS)
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
        #else
        Window("Ad Nope", id: "main") {
            ContentView()
                .environment(FilterStore.shared)
                .frame(minWidth: 460, idealWidth: 520, minHeight: 560, idealHeight: 720)
                .onAppear { BackgroundRefresh.schedule() }
        }
        .windowResizability(.contentMinSize)
        #endif
    }
}

#if os(iOS)
enum BackgroundRefresh {
    /// Must match BGTaskSchedulerPermittedIdentifiers in Config/App-Info.plist.
    static let identifier = (Bundle.main.bundleIdentifier ?? "blocker") + ".refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#else
/// Checks for new lists about twice a day while the app is running. macOS picks
/// a moment when the Mac is idle and on power.
enum BackgroundRefresh {
    private static let activity: NSBackgroundActivityScheduler = {
        let a = NSBackgroundActivityScheduler(identifier: (Bundle.main.bundleIdentifier ?? "blocker") + ".refresh")
        a.repeats = true
        a.interval = 12 * 3600
        a.tolerance = 2 * 3600
        a.qualityOfService = .utility
        return a
    }()
    private static var scheduled = false

    static func schedule() {
        guard !scheduled else { return }
        scheduled = true
        activity.schedule { done in
            Task { @MainActor in
                await FilterStore.shared.updateIfStale(maxAge: 6 * 3600)
                done(.finished)
            }
        }
    }
}
#endif
