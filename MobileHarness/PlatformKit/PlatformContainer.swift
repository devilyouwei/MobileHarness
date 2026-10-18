import Foundation
import Synchronization

public struct PlatformCleanupFailure: Error { public let errors: [any Error] }

public enum PlatformError: Error, Sendable { case unavailable, stopped, busy }

/// A synchronous fence shared by native owners; closing it never asserts physical completion.
public final class PlatformAdmission: Sendable {
    private let open = Mutex(false)
    private let failure: @Sendable (String, String, any Error) -> Void
    public init(onFailure: @escaping @Sendable (String, String, any Error) -> Void = { _, _, _ in }) {
        failure = onFailure
    }
    public func report(_ component: String, _ operation: String, _ error: any Error) {
        guard !(error is CancellationError) else { return }
        // A deliberately closed admission fence is normal lifecycle control, not device failure.
        if let error = error as? PlatformError, error == .unavailable || error == .stopped { return }
        failure(component, operation, error)
    }
    public var isOpen: Bool { open.withLock { $0 } }
    public func check() throws { guard open.withLock({ $0 }) else { throw PlatformError.unavailable } }
    func setOpen(_ value: Bool) { open.withLock { $0 = value } }
}

/// App-owned native root. Construction/start have no permission or capture effects.
@MainActor
public final class PlatformContainer {
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
        },
        onFailure: @escaping @Sendable (String, String, any Error) -> Void = { _, _, _ in }
    ) {
        let admission = PlatformAdmission(onFailure: onFailure)
        self.admission = admission
        audio = AudioContainer(admission: admission)
        vision = VisionContainer(admission: admission)
        connectivity = makeConnectivity(admission)
    }
    public var isAvailable: Bool { admission.isOpen }
    public func start() throws {
        do {
            guard !stopped else { throw PlatformError.stopped }
            guard !started else { return }
            started = true
            admission.setOpen(true)
        } catch {
            admission.report("root", "start", error)
            throw error
        }
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
        do {
            if !active { invalidate() }
            try await suspension?.value
            if active {
                guard started, !stopped else { throw PlatformError.stopped }
                suspension = nil
                admission.setOpen(true)
            }
        } catch {
            admission.report("root", "setForeground", error)
            throw error
        }
    }
    public func stop() async throws {
        do {
            if let shutdown { return try await shutdown.value }
            stopped = true
            invalidate()
            let suspension = suspension
            let task = Task { if let suspension { try await suspension.value } }
            shutdown = task
            try await task.value
        } catch {
            admission.report("root", "stop", error)
            throw error
        }
    }
}
