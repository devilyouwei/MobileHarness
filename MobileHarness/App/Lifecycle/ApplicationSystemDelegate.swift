import Actions

#if os(iOS)

    import UIKit
    import UI
    import OSLog

    /// Native callbacks are forwarded to the registered domain handler without interpreting payloads.
    @MainActor final class ApplicationSystemDelegate: NSObject, UIApplicationDelegate {
        private let handler = ModelDownloadBackgroundService()
        func connect(prepare: @escaping @MainActor () async throws -> Void) { handler.connect(prepare: prepare) }
        func applicationWillTerminate(_ application: UIApplication) {
            if !IslandProcessLifecycle.endBeforeTermination() {
                Logger(subsystem: "dev.mobileharness.app", category: "termination")
                    .error("Live Activity cleanup did not complete before the termination deadline")
            }
        }
        func applicationDidEnterBackground(_ application: UIApplication) {
            handler.applicationDidEnterBackground(application)
        }
        func applicationWillEnterForeground(_ application: UIApplication) {
            handler.applicationWillEnterForeground(application)
        }
        func application(
            _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
            completionHandler: @escaping () -> Void
        ) {
            handler.application(
                application, handleEventsForBackgroundURLSession: identifier, completionHandler: completionHandler)
        }
    }
#endif
