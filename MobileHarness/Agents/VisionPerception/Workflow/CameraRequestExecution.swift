import AgentCore
import Foundation
import FunctionContracts
import Gateway
import UI

extension VisionPerceptionAgent {
    func handleUI(_ value: CameraInput, context: ProcessingContext) async throws -> String? {
        guard let operation = CameraCaptureIntent.Operation(rawValue: value.operation.rawValue) else {
            throw CommunicationError.invalidPayload
        }
        let consumer = try uiExecution.begin(context.requestID)
        defer { uiExecution.finish(context.requestID) }
        let intent = CameraCaptureIntent(
            operation, facing: value.facing.map { $0 == .front ? .front : .back }, previewID: value.previewID,
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
                guard let pendingEnvelope = try uiExecution.next(context.requestID, maximumCalls: 1) else {
                    throw CommunicationError.invalidPayload
                }
                let envelope = pendingEnvelope.bindingResources(
                    value.previewSession.map { ["actions.camera.preview": $0] } ?? [:])
                let result: OutputExecutionResult
                if case .toolCall = envelope.output {
                    result = try await executeCameraTool(envelope, using: consumer)
                    outcome = result
                } else {
                    result = try await consumer.execute(envelope)
                }
                if result.failure != nil { throw CameraIntentFailure.execution(result) }
                if case .control(let state) = envelope.output, state.hasPrefix("visionPerception.camera.") {
                    guard let outcome else { throw CommunicationError.invalidPayload }
                    guard !outcome.isError else { throw CameraIntentFailure.execution(outcome) }
                    return outcome.tool?.value
                }
            }
            throw CommunicationError.capacityExceeded
        } catch {
            let original = error
            let cleanup = Task.detached { [self] in
                try await AgentUIInputs.$owner.withValue(descriptor.id) {
                    let cancellation = CameraCaptureIntent(.cancel, requestID: context.requestID)
                    try await self.receive(cancellation.input(sessionID: self.sessionID))
                }
            }
            do { try await cleanup.value } catch { throw NativeCleanupFailure(errors: [original, error]) }
            throw error
        }
    }
}
