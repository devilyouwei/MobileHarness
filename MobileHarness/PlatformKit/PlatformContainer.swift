import Foundation
import Synchronization

public struct PlatformCleanupFailure: Error { public let errors: [any Error] }

public enum PlatformError: Error, Sendable { case unavailable, stopped, busy }

/// A synchronous fence shared by native owners; closing it never asserts physical completion.
public final class PlatformAdmission: Sendable {
    private let open = Mutex(false)
    public init() {}
    public var isOpen: Bool { open.withLock { $0 } }
    public func check() throws { guard open.withLock({ $0 }) else { throw PlatformError.unavailable } }
    func setOpen(_ value: Bool) { open.withLock { $0 = value } }
}

/// App-owned native root. Construction/start have no permission or capture effects.
@MainActor public final class PlatformContainer {
    public let audio: AudioContainer
    public let vision: VisionContainer
    public let connectivity: ConnectivityContainer
    private let admission: PlatformAdmission
    private var started = false
    private var stopped = false
    private var suspension: Task<Void, any Error>?
    private var shutdown: Task<Void, any Error>?
    public init(
        makeConnectivity: @MainActor (PlatformAdmission) -> ConnectivityContainer = {
            ConnectivityContainer(admission: $0)
        }
    ) {
        let admission = PlatformAdmission()
        self.admission = admission
        audio = AudioContainer(admission: admission)
        vision = VisionContainer(admission: admission)
        connectivity = makeConnectivity(admission)
    }
    public var isAvailable: Bool { admission.isOpen }
    public func start() throws {
        guard !stopped else { throw PlatformError.stopped }
        guard !started else { return }
        started = true
        admission.setOpen(true)
    }
    public func invalidate() {
        admission.setOpen(false)
        guard suspension == nil else { return }
        suspension = Task { [audio, vision, connectivity] in
            var errors: [any Error] = []
            async let connections: Void = connectivity.stop()
            #if os(iOS)
                async let sound: Void = audio.stop()
                async let image: Void = vision.stop()
                do { try await sound } catch { errors.append(error) }
                await image
            #endif
            do { try await connections } catch { errors.append(error) }
            if !errors.isEmpty { throw PlatformCleanupFailure(errors: errors) }
        }
    }
    public func setForeground(_ active: Bool) async throws {
        if !active { invalidate() }
        try await suspension?.value
        if active {
            guard started, !stopped else { throw PlatformError.stopped }
            suspension = nil
            admission.setOpen(true)
        }
    }
    public func stop() async throws {
        if let shutdown { return try await shutdown.value }
        stopped = true
        invalidate()
        let suspension = suspension
        let task = Task { if let suspension { try await suspension.value } }
        shutdown = task
        try await task.value
    }
}
