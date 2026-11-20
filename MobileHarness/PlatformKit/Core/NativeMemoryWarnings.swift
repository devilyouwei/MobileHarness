import Foundation
import Synchronization

#if os(iOS)
    import UIKit
#endif

/// A system memory warning; carries no business meaning or response.
public struct MemoryWarning: Sendable, Equatable {
    public let observedAt: ContinuousClock.Instant
    public init(observedAt: ContinuousClock.Instant) { self.observedAt = observedAt }
}

/// Observes the system notification for the root's lifetime. Warnings coalesce per subscriber (latest).
final class NativeMemoryWarnings: Sendable {
    private let broadcast = NativeInputBroadcast<MemoryWarning>()
    /// NotificationCenter permits removing an immutable observer token from any thread.
    private struct Token: @unchecked Sendable { let value: any NSObjectProtocol }
    private let token = Mutex<Token?>(nil)
    private let running = Mutex(false)
    private let center: NotificationCenter
    private let name: Notification.Name?

    /// Production observes the iOS memory warning; hosts without one deliver nothing unless a name is injected.
    init(center: NotificationCenter = .default, name: Notification.Name? = NativeMemoryWarnings.systemName) {
        self.center = center
        self.name = name
    }

    static var systemName: Notification.Name? {
        #if os(iOS)
            UIApplication.didReceiveMemoryWarningNotification
        #else
            nil
        #endif
    }

    func start() {
        guard
            running.withLock({ state in
                defer { state = true }
                return !state
            })
        else { return }
        guard let name else { return }
        let broadcast = broadcast
        let observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            broadcast.send(MemoryWarning(observedAt: .now))
        }
        token.withLock { $0 = Token(value: observer) }
    }

    func stop() {
        running.withLock { $0 = false }
        let observer = token.withLock { value in
            defer { value = nil }
            return value
        }
        if let observer { center.removeObserver(observer.value) }
        broadcast.finish()
    }

    func listen() throws -> StateSignalListener<MemoryWarning> {
        guard running.withLock({ $0 }) else { throw PlatformError.unavailable }
        return try broadcast.listen(.latest, producer: "platform.system.memory")
    }
}
