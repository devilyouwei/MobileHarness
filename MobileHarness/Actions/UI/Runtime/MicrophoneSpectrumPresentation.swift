import Foundation
import FunctionContracts
import PlatformKit
import UI

/// Trusted measurement presentation, independent of model calls and raw PCM transport.
@MainActor public final class MicrophoneSpectrumPresentation: SpectrumPresenting {
    public typealias Handle = UUID
    private var token: UIPresentationToken?
    public enum Failure: Error { case invalidScope, invalidMeasurement }
    private let state: any ConversationPresenting
    private var active: UUID?
    public init(state: any ConversationPresenting) { self.state = state }
    public func begin(sessionID: String, captureGeneration: String) throws -> Handle {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 128,
            !captureGeneration.isEmpty, captureGeneration.utf8.count <= 128
        else { throw Failure.invalidScope }
        let handle = UUID()
        token = state.token
        active = handle
        return handle
    }
    @discardableResult public func present(_ spectrum: [Float], using handle: Handle) throws -> Bool {
        guard spectrum.count == AudioSpectrum.bandCount,
            spectrum.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { throw Failure.invalidMeasurement }
        guard active == handle, state.accepts(token) else { return false }
        return state.present(
            .microphoneSpectrum(AudioSpectrum.smooth(spectrum, previous: state.microphoneSpectrum)), token: token
        )
    }
    @discardableResult public func finish(_ handle: Handle) -> Bool {
        guard active == handle else { return false }
        active = nil
        guard state.accepts(token) else { return false }
        return state.present(.microphoneSpectrum(AudioSpectrum.silence), token: token)
    }
}
