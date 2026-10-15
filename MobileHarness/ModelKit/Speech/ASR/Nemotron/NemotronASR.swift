import Foundation
import ModelKit

/// Standalone streaming capability. Does not request microphone access, download, or register with a Gateway.
@available(iOS 18, macOS 15, *)
public actor NemotronASR: SpeechRecognitionCapability {

    private let resource: ModelResource<LocalNemotronEngine>
    private let admission = OperationAdmission()
    private let root: URL

    public init(context: ModelContext, artifacts: URL) throws {
        root = artifacts
        resource = try context.resource { try await LocalNemotronEngine(artifacts: artifacts) }
    }
    public var availability: CapabilityAvailability {
        #if !arch(arm64)
            return .unavailable(reason: "Nemotron Core ML requires Apple Silicon")
        #else
            do {
                _ = try LocalNemotronEngine.validateResources(at: root)
                return .available
            } catch { return .unavailable(reason: "Nemotron Core ML resources are missing or incompatible: \(error)") }
        #endif
    }

    public func warmup() async throws {
        let lease = try await resource.acquire()
        do {
            let session = try await lease.model.makeSession(language: "auto")
            do {
                _ = try await admission.run { try await session.feed(samples: Array(repeating: 0, count: 5120)) }
                _ = try await admission.run { try await session.finish() }
            } catch {
                await session.cancel()
                throw error
            }
            await session.cancel()
            await resource.release(lease.id)
        } catch {
            await resource.release(lease.id)
            throw error
        }
    }

    public func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
        try Task.checkCancellation()
        guard request.format.sampleRate == 16_000, request.format.channels == 1, request.format.encoding == .float32
        else {
            throw CapabilityError.invalidRequest("Nemotron requires 16 kHz mono Float32 PCM")
        }
        guard (try LocalNemotronEngine.validateResources(at: root))[request.locale] != nil else {
            throw CapabilityError.invalidRequest("Unknown Nemotron language: \(request.locale)")
        }
        let lease = try await resource.acquire()
        do {
            let resource = resource
            let leaseID = lease.id
            let bridge = NemotronSessionBridge(
                session: try await lease.model.makeSession(language: request.locale), admission: admission,
                release: { await resource.release(leaseID) })
            let pair = InferenceSession<TranscriptionEvent>.make(
                context: request.context, limits: try StreamLimits(capacity: 128, maximumEventBytes: 65_600),
                estimatedBytes: { $0.estimatedBytes },
                onTermination: { _ in
                    Task {
                        await bridge.stop()
                    }
                })
            await resource.setCancellation(leaseID) { [weak session = pair.session] in session?.cancel() }
            return SpeechRecognitionSession(
                output: pair.session, format: request.format,
                sendAudio: { frame in try await bridge.feed(frame, emitter: pair.emitter) },
                finishInput: { try await bridge.finish(emitter: pair.emitter) })
        } catch {
            await resource.release(lease.id)
            throw error
        }
    }
}

@available(iOS 18, macOS 15, *)
private actor NemotronSessionBridge {
    private var session: LocalNemotronSession?
    private let admission: OperationAdmission
    private let release: @Sendable () async -> Void
    private let segment = UUID().uuidString
    private var revision: UInt64 = 0
    private var lastText = ""
    init(
        session: LocalNemotronSession, admission: OperationAdmission, release: @escaping @Sendable () async -> Void
    ) {
        self.session = session
        self.admission = admission
        self.release = release
    }
    func feed(_ frame: AudioFrame, emitter: InferenceEmitter<TranscriptionEvent>) async throws {
        guard let session else { throw CancellationError() }
        guard frame.sampleCount <= 16_000 else {
            throw CapabilityError.invalidRequest("Nemotron packets must not exceed one second")
        }
        let samples = frame.data.withUnsafeBytes { bytes in
            (0..<frame.sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        let text = try await admission.run { try await session.feed(samples: samples) }
        guard self.session != nil else { throw CancellationError() }
        if text != lastText { try emit(text, final: false, to: emitter) }
    }
    func finish(emitter: InferenceEmitter<TranscriptionEvent>) async throws {
        guard let session else { throw CancellationError() }
        let text = try await admission.run { try await session.finish() }
        guard self.session != nil else { throw CancellationError() }
        await stop()
        try emit(text, final: true, to: emitter)
        emitter.finish()
    }
    private func emit(_ text: String, final: Bool, to emitter: InferenceEmitter<TranscriptionEvent>) throws {
        guard text.utf8.count <= 65_536 else { throw CapabilityError.eventTooLarge }
        try emitter.yield(TranscriptionEvent(segmentID: segment, revision: revision, text: text, isFinal: final))
        revision += 1
        lastText = text
    }
    func stop() async {
        guard let session else { return }
        self.session = nil
        await session.cancel()
        await release()
    }
}
