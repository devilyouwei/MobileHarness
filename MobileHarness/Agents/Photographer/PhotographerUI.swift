import AgentCore
import Foundation
import FunctionContracts
import Gateway
import UI

extension PhotographerAgent {
    public func bindUIExecution(_ consumer: GatewayOutputConsumer) async {
        uiExecution.consumer = consumer
        await island.bind(consumer: consumer, source: descriptor.id)
        await island.start()
    }
    func startUIInputs() async throws {
        if let uiAlbum {
            let source = await uiAlbum.requests
            let task = try await consumeUI(source, sessionID: sessionID) { agent, value, context in
                try await agent.handleAlbum(value, context: context)
            }
            uiInputs.append(task)
        }
        guard let uiCamera else { return }
        try await startCameraFacts(uiCamera)
        let source = await uiCamera.requests
        let task = try await consumeUI(source, sessionID: sessionID) { agent, value, context in
            try await agent.handleUI(value, context: context)
        }
        uiInputs.append(task)
    }
    func stopUIInputs() async {
        cameraFacts?.cancel()
        await cameraFacts?.value
        cameraFacts = nil
        await island.submit(nil)
        await uiInputs.retire(for: descriptor.id)()
    }
    private func handleAlbum(_ value: AlbumInput, context: ProcessingContext) async throws -> AlbumReply {
        guard status().lifecycle == .running, context.sessionID == sessionID else {
            throw CommunicationError.scopeClosed
        }
        let consumer = try uiExecution.begin(context.requestID)
        defer { uiExecution.finish(context.requestID) }
        let request = ActionRequestSlot<AlbumInput, AlbumReply>(
            input: value, requestID: context.requestID, sessionID: sessionID)
        let call = try InternalTool(path: "Camera.Album.perform").call([:])
        let envelope = OutputEnvelope(
            source: descriptor.id, context: context, output: .toolCall(call), executionAttachment: request)
        let result = try await consumer.execute(envelope)
        if result.isError {
            // take preserves the original storage/platform failure when the handler ran.
            _ = try await request.take()
            throw PhotographerIntentFailure.execution(result)
        }
        return try await request.take()
    }
    private func startCameraFacts(_ camera: UICameraContainer) async throws {
        guard cameraFacts == nil else { return }
        let stream = try await camera.observeFacts()
        cameraFacts = Task { [self] in
            for await value in stream {
                guard !Task.isCancelled else { return }
                await island.submit(Self.cameraContent(value))
                cameraFactSequence += 1
                let sequence = cameraFactSequence
                let fact = await MainActor.run {
                    let displayedID: String?
                    #if os(iOS)
                        displayedID = value.capturedPhoto?.id
                    #else
                        displayedID = nil
                    #endif
                    return CameraStateObservation(
                        sequence: sequence,
                        enabled: value.isEnabled, visible: value.isVisible, busy: value.isBusy || value.photoBusy,
                        needsSettings: value.needsSettings, facing: value.facing == .front ? .front : .back,
                        displayedMediaID: displayedID, savedMediaID: value.savedMediaID, failure: value.message)
                }
                do { try await receive(fact.input(sessionID: sessionID)) } catch { cameraObservationFailure(error) }
            }
            if !Task.isCancelled { cameraObservationFailure(UIRequestError.consumerEnded) }
        }
    }
    private func handleUI(_ value: CameraInput, context: ProcessingContext) async throws -> String? {
        guard let operation = PhotographerCameraIntent.Operation(rawValue: value.operation.rawValue) else {
            throw CommunicationError.invalidPayload
        }
        let consumer = try uiExecution.begin(context.requestID)
        defer { uiExecution.finish(context.requestID) }
        let intent = PhotographerCameraIntent(
            operation, facing: value.facing.map { $0 == .front ? .front : .back }, mediaID: value.mediaID,
            settings: value.settings.map {
                CameraCaptureSettings(
                    mode: $0.mode, delaySeconds: $0.delaySeconds, flash: $0.flash, zoom: $0.zoom,
                    durationSeconds: $0.durationSeconds)
            },
            recordingID: value.recordingID, requestID: context.requestID)
        do {
            try intent.message.validate()
            try await receive(context.input(.observation(intent.message)))
            var outcome: OutputExecutionResult?
            for _ in 0..<8 {
                try Task.checkCancellation()
                guard let envelope = try uiExecution.next(context.requestID, maximumCalls: 1) else {
                    throw CommunicationError.invalidPayload
                }
                let result: OutputExecutionResult
                if case .toolCall = envelope.output {
                    result = try await consumer.executeReturning(envelope)
                } else {
                    result = try await consumer.execute(envelope)
                }
                if case .toolCall = envelope.output { outcome = result }
                if result.failure != nil { throw PhotographerIntentFailure.execution(result) }
                if case .control(let state) = envelope.output, state.hasPrefix("photographer.camera.") {
                    guard let outcome else { throw CommunicationError.invalidPayload }
                    guard !outcome.isError else { throw PhotographerIntentFailure.execution(outcome) }
                    return outcome.tool?.value
                }
            }
            throw CommunicationError.capacityExceeded
        } catch {
            let original = error
            let cleanup = Task.detached { [self] in
                try await AgentUIInputs.$owner.withValue(descriptor.id) {
                    let cancellation = PhotographerCameraIntent(.cancel, requestID: context.requestID)
                    try await self.receive(cancellation.input(sessionID: self.sessionID))
                }
            }
            do { try await cleanup.value } catch { throw NativeCleanupFailure(errors: [original, error]) }
            throw error
        }
    }
}

// Photographer owns camera activity semantics; execution facts arrive on its existing input.
extension PhotographerAgent {
    @MainActor static func cameraContent(_ camera: CameraPresentationSnapshot) -> IslandContent? {
        if let remaining = camera.countdown {
            return .init(
                title: "拍照倒计时", subtitle: "\(remaining) 秒", primary: .symbol(name: "timer"), priority: .critical,
                secondary: .progress(1 / Double(max(1, remaining))),
                liveActivity: true)
        }
        if camera.photoBusy {
            return .init(
                title: "正在处理照片", primary: .symbol(name: "camera.aperture"), priority: .critical, secondary: .loading)
        }
        let recording = camera.recording
        if recording.active {
            let title = recording.phase == .starting ? "正在启动录像" : recording.phase == .finishing ? "录像正在收尾" : "正在录像"
            return .init(
                title: title, subtitle: "聆听已暂停", primary: .symbol(name: "video.fill"), tone: .recording,
                priority: .attention,
                secondary: recording.phase == .recording
                    ? .symbol(name: "record.circle.fill", effect: .pulse) : .loading,
                startedAt: recording.phase == .recording ? recording.startedAt : nil,
                liveActivity: true)
        }
        if camera.recordedVideo != nil {
            return .init(
                title: "录像待处置", subtitle: "打开相机保存或忽略", primary: .symbol(name: "video"), priority: .high)
        }
        #if os(iOS)
            if camera.capturedPhoto != nil {
                return .init(
                    title: "照片待处置", subtitle: "打开相机保存或忽略", primary: .symbol(name: "photo"), priority: .high)
            }
        #endif
        return nil
    }
}
