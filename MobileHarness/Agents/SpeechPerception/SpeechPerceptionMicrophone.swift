import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import PlatformKit

/// Bounded, low-frequency measurement. Raw PCM stays in the perception role.
public struct MicrophoneObservation: Sendable {
    public let layout: MicrophoneChannelLayout
    public let sampleRate: Int
    public let rms: Float
    public let capturedAt: ContinuousClock.Instant
}

extension SpeechPerceptionAgent {
    /// Attach to already admitted hardware; this read-only operation cannot open the microphone.
    public func startInput(sessionID: String) async throws {
        guard nativeInput == nil, nativeInputEpoch == nil else { throw CapabilityError.inputBusy }
        guard let microphoneInput else { throw CapabilityError.unavailable("Microphone input was not injected") }
        _ = try admitsMicrophone(sessionID: sessionID)
        let epoch = UUID()
        nativeInputEpoch = epoch
        do {
            let capture = try await microphoneInput.subscribeCapture()
            setCaptureDuplex(capture.supportsFullDuplex)
            try Task.checkCancellation()
            guard nativeInputEpoch == epoch else { throw CancellationError() }
            _ = try admitsMicrophone(sessionID: sessionID)
            bindMicrophoneGeneration(capture.generation)
            nativeInput = Task { try await self.consumeMicrophone(capture, sessionID: sessionID, epoch: epoch) }
        } catch {
            if nativeInputEpoch == epoch { nativeInputEpoch = nil }
            throw error
        }
    }
    public func waitForInput() async throws { try await nativeInput?.value }
    public func stopInput() async {
        nativeInputEpoch = nil
        let task = nativeInput
        // Half-duplex retirement joins accepted processing, including final transcription publication.
        if !nativeProcessing { task?.cancel() }
        _ = await task?.result
        await retireMicrophonePublications()
        if nativeInputEpoch == nil {
            nativeInput = nil
            bindMicrophoneGeneration(nil)
        }
    }
    private func consumeMicrophone(_ capture: MicrophoneCaptureInput, sessionID: String, epoch: UUID) async throws {
        let display = try await microphoneSpectrum?.begin(sessionID: sessionID, captureGeneration: capture.generation)
        do { try await consumeMicrophone(capture, sessionID: sessionID, epoch: epoch, display: display) } catch {
            if let display { await microphoneSpectrum?.finish(display) }
            throw error
        }
        if let display { await microphoneSpectrum?.finish(display) }
    }
    private func consumeMicrophone(
        _ capture: MicrophoneCaptureInput, sessionID: String, epoch: UUID,
        display: UUID?
    ) async throws {
        var meterSamples: [Float] = []
        var meterRate = 0
        var lastMeterUpdate = ContinuousClock.now
        var lastObservation: ContinuousClock.Instant?
        for try await frame in capture.frames {
            try Task.checkCancellation()
            guard nativeInputEpoch == epoch else { throw CancellationError() }
            // Listening policy and playback admission are actor-owned; no per-packet MainActor callback.
            guard try admitsMicrophone(sessionID: sessionID) else {
                suppressedMicrophonePackets += 1
                continue
            }
            ContainerInputMetrics.record("PCM.Admit", since: frame.capturedAt)
            // Process inline in this lifetime task; the native FIFO supplies the only pending PCM queue.
            try await processMicrophone(frame, sessionID: sessionID, captureGeneration: capture.generation)
            guard nativeInputEpoch == epoch else { throw CancellationError() }
            if let microphoneObservation,
                lastObservation.map({ $0.duration(to: .now) >= .milliseconds(100) }) ?? true
            {
                let observation = MicrophoneObservation(
                    layout: frame.layout, sampleRate: frame.sampleRate, rms: frame.rms, capturedAt: frame.capturedAt)
                await microphoneObservation(observation)
                lastObservation = .now
            }
            if let microphoneSpectrum, let display {
                if meterRate != frame.sampleRate {
                    meterSamples.removeAll(keepingCapacity: true)
                    meterRate = frame.sampleRate
                }
                meterSamples.append(contentsOf: frame.omnidirectionalSamples.suffix(AudioSpectrum.sampleCount))
                if meterSamples.count > AudioSpectrum.sampleCount {
                    meterSamples.removeFirst(meterSamples.count - AudioSpectrum.sampleCount)
                }
                if lastMeterUpdate.duration(to: .now) >= .milliseconds(33) {
                    let spectrum = try await AudioSpectrum.measureOffMain(meterSamples, sampleRate: meterRate)
                    try Task.checkCancellation()
                    guard nativeInputEpoch == epoch, try admitsMicrophone(sessionID: sessionID) else { continue }
                    try await microphoneSpectrum.present(spectrum, using: display)
                    lastMeterUpdate = .now
                }
            }
        }
        try Task.checkCancellation()
    }
}
