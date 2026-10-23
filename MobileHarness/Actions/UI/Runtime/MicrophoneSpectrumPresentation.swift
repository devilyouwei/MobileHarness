import Foundation
import PlatformKit
import UI

/// Trusted measurement presentation, independent of model calls and raw PCM transport.
@MainActor public final class MicrophoneSpectrumPresentation {
    public struct Handle: Sendable {
        fileprivate let id: UUID
        fileprivate let token: UIPresentationToken?
    }
    public enum Failure: Error { case invalidScope, invalidMeasurement }
    private let state: any ConversationPresenting
    private var active: UUID?
    public init(state: any ConversationPresenting) { self.state = state }
    public func begin(sessionID: String, captureGeneration: String) throws -> Handle {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 128,
            !captureGeneration.isEmpty, captureGeneration.utf8.count <= 128
        else { throw Failure.invalidScope }
        let handle = Handle(id: UUID(), token: state.token)
        active = handle.id
        return handle
    }
    @discardableResult public func present(_ spectrum: [Float], using handle: Handle) throws -> Bool {
        guard spectrum.count == AudioSpectrum.bandCount,
            spectrum.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { throw Failure.invalidMeasurement }
        guard active == handle.id, state.accepts(handle.token) else { return false }
        return state.present(
            .microphoneSpectrum(AudioSpectrum.smooth(spectrum, previous: state.microphoneSpectrum)), token: handle.token
        )
    }
    @discardableResult public func finish(_ handle: Handle) -> Bool {
        guard active == handle.id else { return false }
        active = nil
        guard state.accepts(handle.token) else { return false }
        return state.present(.microphoneSpectrum(AudioSpectrum.silence), token: handle.token)
    }
}
