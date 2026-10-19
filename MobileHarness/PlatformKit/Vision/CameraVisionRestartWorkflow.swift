import Foundation

/// Root-owned latest-intent replacement. Native camera switching never waits on perception cleanup.
@MainActor
public final class CameraVisionRestartWorkflow<Intent: Sendable> {
    private let start: (Intent) -> Task<Void, Never>?
    private var active: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var pending: Intent?
    private var revision: UInt64 = 0
    public init(start: @escaping (Intent) -> Task<Void, Never>?) { self.start = start }

    public func replace(with intent: Intent) {
        revision &+= 1
        pending = intent
        active?.cancel()
        guard worker == nil else { return }
        worker = Task {
            defer { worker = nil }
            while pending != nil {
                await active?.value
                active = nil
                guard let latest = pending else { return }
                pending = nil
                active = start(latest)
            }
        }
    }
    public func invalidate() {
        revision &+= 1
        pending = nil
        active?.cancel()
    }
    public func stop() async {
        invalidate()
        let stoppingRevision = revision
        let retiring = active
        await worker?.value
        await retiring?.value
        if revision == stoppingRevision { active = nil }
    }
}
