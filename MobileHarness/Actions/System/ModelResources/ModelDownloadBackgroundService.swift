#if os(iOS)
    import Foundation
    import UIKit
    import PlatformKit
    import ModelKitDefaults
    import ModelKitHub
    import ModelKitRuntime

    @MainActor
    @available(iOS 27, *)
    public final class ModelDownloadBackgroundService: NSObject, UIApplicationDelegate {
        private var completions: [String: (String, () -> Void)] = [:]
        private var prepare: (@MainActor () async throws -> Void)?
        public func connect(prepare: @escaping @MainActor () async throws -> Void) { self.prepare = prepare }
        private let allowance = NativeBackgroundAllowance()
        public private(set) var lastFailure: String?
        public func applicationDidEnterBackground(_ application: UIApplication) {
            allowance.begin(name: "Model download preparation", duration: .seconds(25))
        }
        public func applicationWillEnterForeground(_ application: UIApplication) { allowance.end() }

        public func application(
            _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
            completionHandler: @escaping () -> Void
        ) {
            guard identifier.hasPrefix("dev.mobileharness.artifacts.") else {
                completionHandler()
                return
            }
            guard completions[identifier] != nil || completions.count < 10 else {
                lastFailure = "Model background handoff capacity exceeded"
                completionHandler()
                return
            }
            completions.removeValue(forKey: identifier)?.1()
            let generation = UUID().uuidString
            completions[identifier] = (generation, completionHandler)
            Task {
                do {
                    guard let prepare else { throw ModelArtifactError.storage }
                    try await prepare()
                } catch {
                    lastFailure = String(String(describing: error).prefix(2048))
                    finish(identifier, generation: generation)
                }
            }
            ModelArtifactBackgroundEvents.register(identifier) { [weak self] in
                Task { @MainActor in self?.finish(identifier, generation: generation) }
            }
        }
        private func finish(_ identifier: String, generation: String) {
            guard completions[identifier]?.0 == generation else { return }
            completions.removeValue(forKey: identifier)?.1()
        }

    }

#endif
