import Actions
import AgentCore
import Foundation
import Gateway
import UI

extension PhotographerAgent {
    public func bindUIExecution(_ consumer: GatewayOutputConsumer) { uiExecution.consumer = consumer }
    func startUIInputs() async throws {
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
        await uiInputs.retire(for: descriptor.id)()
    }
    private func startCameraFacts(_ camera: UICameraContainer) async throws {
        guard cameraFacts == nil else { return }
        let stream = try await camera.observeFacts()
        cameraFacts = Task { [self] in
            for await value in stream {
                guard !Task.isCancelled else { return }
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
            requestID: context.requestID)
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
