import Foundation

/// Finite named native scopes. The session fence rejects conflicting owners rather than replacing them.
@MainActor
public final class AudioContainer {
    public enum Scope: CaseIterable, Sendable { case voice, diagnostic, detection, camera }
    private let admission: PlatformAdmission
    #if os(iOS)
        private var instances: [Scope: AppleAudioIO] = [:]
        private var cues: [Scope: NativeCuePlayback] = [:]
        private var haptics: [Scope: NativeHapticFeedback] = [:]
        private var owner: Scope?
        public func io(_ scope: Scope) -> any AudioInputOutput {
            if let existing = instances[scope] { return existing }
            let value = AppleAudioIO(
                platformAdmission: admission,
                admitAvailability: { [admission] in try admission.check() },
                admit: { [weak self] in
                    guard let self else { throw PlatformError.stopped }
                    try self.admission.check()
                    guard self.owner == nil || self.owner == scope else { throw PlatformError.busy }
                    self.owner = scope
                },
                release: { [weak self] in
                    if self?.owner == scope { self?.owner = nil }
                })
            instances[scope] = value
            return value
        }
        public func cue(_ scope: Scope) -> any CuePlaying {
            if let value = cues[scope] { return value }
            let value = NativeCuePlayback(admission: admission)
            cues[scope] = value
            return value
        }
        public func haptic(_ scope: Scope) -> any HapticFeedbackProviding {
            if let value = haptics[scope] { return value }
            let value = NativeHapticFeedback(admission: admission)
            haptics[scope] = value
            return value
        }
        func stop() async throws {
            for cue in cues.values { await cue.stopAndWait() }
            for haptic in haptics.values { await haptic.stop() }
            for io in instances.values { await io.stop() }
            owner = nil
            let failures = instances.values.compactMap(\.cleanupFailure)
            if let primary = failures.first {
                throw PlatformFailure(
                    component: "audio", operation: "stop", underlying: primary,
                    cleanupErrors: Array(failures.dropFirst()), code: .cleanupFailed)
            }
        }
    #endif
    public init(admission: PlatformAdmission) { self.admission = admission }
}
