#if canImport(CoreAI)
    import CoreAI
    import Foundation
    import ModelKit

    /// Standalone streaming capability. Does not request microphone access, download, or register with a Gateway.
    @available(iOS 27, macOS 27, *)
    public actor NemotronASR: SpeechRecognitionCapability {

        private let resource: ModelResource<NemotronModel>
        private let admission = OperationAdmission()
        private let root: URL

        public init(context: ModelContext, artifacts: URL) throws {
            root = artifacts
            resource = try context.resource {
                #if os(iOS) && !targetEnvironment(simulator)
                    guard AIModel.deviceArchitectureName == "h18p" else {
                        throw CapabilityError.unavailable(
                            "These iOS AOT artifacts require h18p; obtain a validated export for this device")
                    }
                #elseif !os(macOS) || !arch(arm64)
                    throw CapabilityError.unavailable(
                        "Nemotron requires an Apple Silicon Mac or supported physical iOS device")
                #endif
                return try await NemotronModel(bundleAt: artifacts)
            }
        }
        public var availability: CapabilityAvailability {
            #if targetEnvironment(simulator) || !arch(arm64)
                return .unavailable(reason: "Nemotron CoreAI requires supported physical hardware")
            #else
                guard ComputeUnitKind.availableKinds.contains(.gpu) else {
                    return .unavailable(reason: "CoreAI GPU unavailable")
                }
                guard FileManager.default.fileExists(atPath: root.path) else {
                    return .unavailable(reason: "Model artifacts not installed")
                }
                #if os(iOS)
                    guard AIModel.deviceArchitectureName == "h18p" else {
                        return .unavailable(reason: "No validated Nemotron artifact for this iOS architecture")
                    }
                #endif
                return .available
            #endif
        }
        /// Loads/validates the graphs without starting a recognition session.
        /// Exercise the streaming graphs with synthetic silence without emitting user events.
        public func warmup() async throws {
            let lease = try await resource.acquire()
            do {
                let session = try lease.model.makeSession(language: "en-US")
                _ = try await admission.run { try await session.feed(samples: Array(repeating: 0, count: 5120)) }
                _ = try await admission.run { try await session.finish() }
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
            guard NemotronModel.languages.contains(request.locale) else {
                throw NemotronError.unknownLanguage(request.locale)
            }
            let lease = try await resource.acquire()
            do {
                let resource = resource
                let leaseID = lease.id
                let bridge = NemotronSessionBridge(
                    session: try lease.model.makeSession(language: request.locale), admission: admission,
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

    @available(iOS 27, macOS 27, *)
    private actor NemotronSessionBridge {
        private var session: NemotronStreamSession?
        private let admission: OperationAdmission
        private let release: @Sendable () async -> Void
        private let segment = UUID()
        private var revision: UInt64 = 0
        private var lastText = ""
        init(
            session: NemotronStreamSession, admission: OperationAdmission, release: @escaping @Sendable () async -> Void
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

#endif
