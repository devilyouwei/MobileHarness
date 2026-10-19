import Foundation
import Synchronization

/// A synchronous fence shared by native owners; closing it never asserts physical completion.
public final class PlatformAdmission: Sendable {
    private let open = Mutex(false)
    private let failure: @Sendable (String, String, any Error) -> Void
    public init(onFailure: @escaping @Sendable (String, String, any Error) -> Void = { _, _, _ in }) {
        failure = onFailure
    }
    @discardableResult public func report(
        _ component: String, _ operation: String, _ error: any Error,
        fileID: String = #fileID, function: String = #function, line: UInt = #line
    ) -> PlatformFailure {
        let value = PlatformFailure(
            component: component, operation: operation, underlying: error,
            fileID: fileID, function: function, line: line)
        failure(value.component, value.operation, value)
        return value
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
    public func start() throws(PlatformFailure) {
        do {
            guard !stopped else { throw PlatformError.stopped }
            guard !started else { return }
            started = true
            admission.setOpen(true)
        } catch {
            throw admission.report("root", "start", error)
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
            if let primary = errors.first {
                throw PlatformFailure(
                    component: "root", operation: "invalidate", underlying: primary,
                    cleanupErrors: Array(errors.dropFirst()), code: .cleanupFailed)
            }
        }
    }
    public func setForeground(_ active: Bool) async throws(PlatformFailure) {
        do {
            if !active { invalidate() }
            try await suspension?.value
            if active {
                guard started, !stopped else { throw PlatformError.stopped }
                suspension = nil
                admission.setOpen(true)
            }
        } catch {
            throw admission.report("root", "setForeground", error)
        }
    }
    public func stop() async throws(PlatformFailure) {
        do {
            if let shutdown { return try await shutdown.value }
            stopped = true
            invalidate()
            let suspension = suspension
            let task = Task { if let suspension { try await suspension.value } }
            shutdown = task
            try await task.value
        } catch {
            throw admission.report("root", "stop", error)
        }
    }
}
