import Foundation

/// Independent utterance denoising, not echo cancellation or a continuous streaming processor.
/// Input: 48 kHz mono Float32, 1...240000 samples. Output preserves format, count and timing.
/// Calls reset model/DSP state; overlapping requests reject with inputBusy (no queue).
/// Cancellation joins native work before releasing model resources. No implicit resampling.
public protocol SpeechEnhancementCapability: Capability {
    func enhance(_ audio: AudioFrame) async throws -> AudioFrame
}
