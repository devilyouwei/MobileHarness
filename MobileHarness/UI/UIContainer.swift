import Foundation

public enum UIContainerError: Error, Sendable, Equatable { case unavailable, stopped }

/// App-scoped passive UI root. It never starts a device, model or renderer.
@MainActor public final class UIContainer {
    public let camera: UICameraContainer
    private var started = false
    private var stopped = false
    private var shutdown: Task<Void, Never>?
    public init() { camera = UICameraContainer() }
    public var isAvailable: Bool { camera.isAvailable }
    public func start() throws {
        guard !stopped else { throw UIContainerError.stopped }
        guard !started else { return }
        started = true
        camera.setAvailable(true)
    }
    public func invalidate() { camera.setAvailable(false) }
    public func setForeground(_ active: Bool) throws {
        guard !stopped else { throw UIContainerError.stopped }
        guard started else { throw UIContainerError.unavailable }
        camera.setAvailable(active)
    }
    public func stop() async {
        if let shutdown { return await shutdown.value }
        stopped = true
        invalidate()
        let task = Task { [camera] in await camera.stop() }
        shutdown = task
        await task.value
    }
}
