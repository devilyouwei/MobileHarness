#if os(iOS)
    import Foundation
    import UIKit

    /// One bounded OS preparation allowance. It never promises background device execution.
    @MainActor public final class NativeBackgroundAllowance {
        private var token: UIBackgroundTaskIdentifier = .invalid
        private var expiry: Task<Void, Never>?
        public init() {}
        public func begin(name: String, duration: Duration) {
            end()
            token = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
            expiry = Task { [weak self] in
                do { try await Task.sleep(for: duration) } catch { return }
                self?.end()
            }
        }
        public func end() {
            expiry?.cancel()
            expiry = nil
            if token != .invalid {
                UIApplication.shared.endBackgroundTask(token)
                token = .invalid
            }
        }
    }
#endif
