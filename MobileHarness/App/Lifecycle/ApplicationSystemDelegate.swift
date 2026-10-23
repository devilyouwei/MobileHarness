import Actions

#if os(iOS)

    import UIKit

    /// Native callbacks are forwarded to the registered domain handler without interpreting payloads.
    @MainActor final class ApplicationSystemDelegate: NSObject, UIApplicationDelegate {
        private let handler = ModelDownloadBackgroundService()
        func connect(prepare: @escaping @MainActor () async throws -> Void) { handler.connect(prepare: prepare) }
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
