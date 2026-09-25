import Foundation
import ModelKit
import OSLog
import Speech
import Synchronization

/// Adapter configuration only. Consumers continue to depend on SpeechRecognitionCapability.
public enum AppleSpeechRecognitionPolicy: Sendable {
    case onDeviceOnly
    case allowNetwork

    func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = self == .onDeviceOnly
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        return request
    }
}

/// Adapter only: microphone capture and permission prompts belong to the application/platform layer.
@MainActor
public final class AppleSpeechRecognition: SpeechRecognitionCapability {
    private let locale: String
    private let recognizer: SFSpeechRecognizer?
    private let logger = Logger(subsystem: "dev.mobileharness.speech", category: "recognition")
    /// Applies to new requests; the active worker retains its request's policy.
    public var policy: AppleSpeechRecognitionPolicy
    private let resource: ModelResource<Void>
    private var activeWorker: (id: UUID, worker: RecognitionWorker)?
    public init(context: ModelContext, locale: String = "zh-CN", policy: AppleSpeechRecognitionPolicy = .onDeviceOnly)
        throws
    {
        resource = try context.resource { () }
        self.locale = locale
        self.policy = policy
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
    }

    public var availability: CapabilityAvailability {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return .unavailable(reason: "请先授权语音识别")
        }
        guard let recognizer else {
            return .unavailable(reason: "系统不支持当前识别语言：\(locale)")
        }
        guard policy == .allowNetwork || recognizer.supportsOnDeviceRecognition else {
            return .unavailable(reason: "当前环境不支持 \(locale) 离线语音识别；应用仅启用了离线 ASR，尚未启动录音")
        }
        guard recognizer.isAvailable else {
            return .unavailable(reason: "系统语音识别服务暂不可用，请稍后重试；尚未启动录音")
        }
        return .available
    }

    public func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
        try Task.checkCancellation()
        guard request.locale == locale else { throw CapabilityError.unavailable("识别语言与配置不匹配") }
        guard case .available = availability else {
            if case .unavailable(let reason) = availability { throw CapabilityError.unavailable(reason) }
            throw CapabilityError.unavailable("语音识别不可用")
        }
        guard activeWorker == nil else { throw CapabilityError.inputBusy }
        guard let recognizer else { throw CapabilityError.unavailable("不支持此识别语言") }
        let lease = try await resource.acquire()
        let token = lease.id
        let resource = resource
        let pair = InferenceSession<TranscriptionEvent>.make(
            context: request.context, limits: try StreamLimits(capacity: 128, maximumEventBytes: 16_384),
            estimatedBytes: { $0.estimatedBytes },
            onTermination: { [weak self] termination in
                Task { @MainActor in
                    guard let self else {
                        await resource.release(token)
                        return
                    }
                    if self.activeWorker?.id == token {
                        self.activeWorker?.worker.stop(termination: termination)
                        self.activeWorker = nil
                    }
                    await resource.release(token)
                    switch termination {
                    case .finished:
                        self.logger.info(
                            "ASR finished request=\(token.uuidString, privacy: .public) active=\(self.activeWorker == nil ? 0 : 1)"
                        )
                    case .cancelled:
                        self.logger.info(
                            "ASR cancelled request=\(token.uuidString, privacy: .public) active=\(self.activeWorker == nil ? 0 : 1)"
                        )
                    case .failed(let error):
                        let error = error as NSError
                        self.logger.error(
                            "ASR failed request=\(token.uuidString, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code) active=\(self.activeWorker == nil ? 0 : 1)"
                        )
                    }
                }
            })
        let worker = RecognitionWorker(recognizer: recognizer, policy: policy, emitter: pair.emitter)
        activeWorker = (token, worker)
        logger.info(
            "ASR started request=\(token.uuidString, privacy: .public) active=\(self.activeWorker == nil ? 0 : 1)")
        await resource.setCancellation(token) { [weak session = pair.session] in session?.cancel() }
        return SpeechRecognitionSession(
            output: pair.session, format: request.format,
            sendAudio: { frame in try await worker.send(frame) },
            finishInput: { try await worker.finishInput() })
    }
}

@MainActor
private final class RecognitionWorker {
    private let recognizer: SFSpeechRecognizer
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var stopped = false

    init(
        recognizer: SFSpeechRecognizer, policy: AppleSpeechRecognitionPolicy,
        emitter: InferenceEmitter<TranscriptionEvent>
    ) {
        self.recognizer = recognizer
        request = policy.makeRequest()
        task = recognizer.recognitionTask(with: request, resultHandler: Self.handler(emitter: emitter))
        timeout = Task {
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            let reason = policy == .onDeviceOnly ? "语音识别超时，请检查设备的离线语音资源" : "语音识别超时，请检查网络与系统语音服务"
            emitter.fail(CapabilityError.unavailable(reason))
        }
    }

    nonisolated private static func handler(emitter: InferenceEmitter<TranscriptionEvent>)
        -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void
    {
        let revision = Mutex<UInt64>(0)
        let segment = UUID()
        return { result, error in
            if let result {
                let version = revision.withLock { value in
                    defer { value += 1 }
                    return value
                }
                do {
                    try emitter.yield(
                        TranscriptionEvent(
                            segmentID: segment, revision: version,
                            text: result.bestTranscription.formattedString, isFinal: result.isFinal))
                    if result.isFinal {
                        emitter.finish()
                        return
                    }
                } catch {
                    emitter.fail(error)
                    return
                }
            }
            if let error { emitter.fail(error) }
        }
    }
    func send(_ frame: AudioFrame) throws {
        guard !stopped else { throw CapabilityError.sessionClosed }
        request.append(try PCMCodec.decode(frame))
    }
    func finishInput() throws {
        guard !stopped else { throw CapabilityError.sessionClosed }
        request.endAudio()
    }
    func stop(termination: SessionTermination) {
        guard !stopped else { return }
        stopped = true
        timeout?.cancel()
        timeout = nil
        // A final result already completes the task. Only abort failed/interrupted work.
        if case .finished = termination {} else { task?.cancel() }
        task = nil
    }
}
