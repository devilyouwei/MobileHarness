import Foundation
import FunctionContracts
import ModelKit
import PlatformKit
import Synchronization
import UI

/// Native execution only. Registration and model graph creation belong to the Agent owner.
@MainActor public final class AudioDetectionExecution {
    private let audio: any AudioCaptureControlling
    private let beforeStart: @MainActor () async -> Void
    public init(audio: any AudioCaptureControlling, beforeStart: @escaping @MainActor () async -> Void) {
        self.audio = audio
        self.beforeStart = beforeStart
    }
    public func prepare(update: @escaping @MainActor @Sendable (AudioDetectionSnapshot) -> Void) async throws
        -> AudioDetectionPrepared
    {
        await beforeStart()
        try Task.checkCancellation()
        let scope = AudioDetectionScope(audio: audio, update: update)
        do {
            try await scope.requestPermission()
            return AudioDetectionPrepared(scope: scope)
        } catch {
            let prepared = AudioDetectionPrepared(scope: scope)
            try await prepared.finish(diagnosticError(error))
            throw error
        }
    }
    public func run(_ prepared: AudioDetectionPrepared) async throws {
        let scope = prepared.scope
        var failure: (any Error)?
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await scope.audio.startCapture(preferSpatial: true)
                try Task.checkCancellation()
                scope.apply(scope.audio.captureContext)
                scope.watchAudioChanges()
                if let failure = scope.failure { throw failure }
                guard let speech = scope.session?.perception else { throw AudioDetectionError.perceptionFailed }
                try await speech.startInput(sessionID: scope.id)
                try await speech.waitForInput()
                try Task.checkCancellation()
                throw scope.failure ?? AudioDetectionError.captureEnded
            } onCancel: {
                Task { await prepared.shutdown() }
            }
        } catch {
            scope.apply(scope.audio.captureContext)
            failure = scope.failure ?? diagnosticError(error)
        }
        try await prepared.finish(failure)
    }
}
/// Opaque native scope. Agent sees a read-only source and typed role result callbacks.
@MainActor public final class AudioDetectionPrepared {
    fileprivate let scope: AudioDetectionScope
    private var cleanupReported = false
    fileprivate init(scope: AudioDetectionScope) { self.scope = scope }
    public var id: String { scope.id }
    public var input: any AudioCaptureObserving { scope.audio }
    public func observe(_ value: AudioDetectionObservation) { scope.receive(value) }
    public func fail(_ error: any Error) async { await scope.fail(error) }
    public func install(_ session: AudioDetectionPerception) async throws { try await scope.install(session) }
    public func shutdown() async { await scope.shutdown() }
    public func finish(_ primary: (any Error)? = nil) async throws {
        await scope.shutdown()
        if !cleanupReported, let cleanup = scope.audio.cleanupFailure {
            cleanupReported = true
            if let primary { throw NativeCleanupFailure(errors: [primary, cleanup]) }
            throw cleanup
        }
        if let primary { throw primary }
    }
}

private func diagnosticError(_ error: any Error) -> any Error {
    if error is CancellationError { return error }
    if let error = error as? AudioIOError {
        switch error {
        case .microphoneDenied: return AudioDetectionError.microphoneDenied
        case .invalidFormat: return AudioDetectionError.invalidFormat
        case .overflow: return AudioDetectionError.overflow
        case .busy: return AudioDetectionError.busy
        case .interrupted: return AudioDetectionError.interrupted
        case .startFailed, .runtimeFailed: return error
        }
    }
    return error
}

@MainActor private final class AudioDetectionScope {
    let id = UUID().uuidString
    let audio: any AudioCaptureControlling
    private(set) var session: AudioDetectionPerception?
    var failure: (any Error)?
    private var snapshot = AudioDetectionSnapshot()
    private let update: @MainActor @Sendable (AudioDetectionSnapshot) -> Void
    private var routeTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var closing = false
    init(
        audio: any AudioCaptureControlling,
        update: @escaping @MainActor @Sendable (AudioDetectionSnapshot) -> Void
    ) {
        self.audio = audio
        self.update = update
    }
    func requestPermission() async throws {
        do {
            try await audio.requestPermissions()
            snapshot.permissionGranted = true
        } catch {
            snapshot.permissionGranted = false
            update(snapshot)
            throw error
        }
        try Task.checkCancellation()
    }
    func install(_ session: AudioDetectionPerception) async throws {
        guard !closing, !Task.isCancelled else {
            await session.perception.stop()
            await session.stop()
            throw CancellationError()
        }
        if let failure {
            await session.perception.stop()
            await session.stop()
            throw failure
        }
        self.session = session
    }
    func apply(_ context: AudioCaptureContext) {
        switch context.input {
        case .unknown: snapshot.input = .unknown
        case .builtInMicrophone: snapshot.input = .builtInMicrophone
        case .headset: snapshot.input = .headset
        case .external: snapshot.input = .external
        }
        switch context.spatialSupport {
        case .unknown: snapshot.support = .unknown
        case .supported: snapshot.support = .supported
        case .unsupported: snapshot.support = .unsupported
        case .inputUnavailable: snapshot.support = .inputUnavailable
        }
        switch context.fallback {
        case .none: snapshot.fallback = nil
        case .inputUnavailable: snapshot.fallback = .inputUnavailable
        case .unsupported: snapshot.fallback = .unsupported
        case .startupFailed: snapshot.fallback = .startupFailed
        }
        update(snapshot)
    }
    func watchAudioChanges() {
        do {
            let events = try audio.subscribeEvents()
            routeTask = Task {
                do {
                    for try await event in events {
                        guard !Task.isCancelled else { return }
                        await fail(
                            event == .interrupted
                                ? AudioDetectionError.interrupted : AudioDetectionError.routeChanged)
                        return
                    }
                } catch { await fail(error) }
            }
        } catch { failure = error }
    }
    func receive(_ observation: AudioDetectionObservation) {
        guard !closing else { return }
        switch observation {
        case .microphone(let layout, let rate, let rms, let at):
            snapshot.capture = layout == .mono ? .mono : .spatial
            snapshot.sampleRate = rate
            snapshot.signal = .receiving
            snapshot.capturedAt = at
            let level = Double(rms)
            snapshot.level = level.isFinite ? min(1, max(0, (20 * log10(max(level, 0.000001)) + 60) / 60)) : 0
            if layout == .mono { snapshot.direction = .unavailable }
        case .direction(let state, let azimuth, let elevation, let expiresAt):
            snapshot.direction = state
            snapshot.azimuthDegrees = azimuth.map { $0 * 180 / .pi }
            snapshot.elevationDegrees = elevation.map { $0 * 180 / .pi }
            snapshot.directionExpiresAt = expiresAt
        }
        update(snapshot)
    }
    func fail(_ error: any Error) async {
        guard !closing, failure == nil else { return }
        failure = error
        await audio.stopCapture()
    }
    func shutdown() async {
        if shutdownTask == nil {
            closing = true
            routeTask?.cancel()
            shutdownTask = Task {
                await audio.stop()
                await session?.perception.stop()
                await session?.stop()
                await routeTask?.value
                session = nil
            }
        }
        await shutdownTask?.value
    }
}
