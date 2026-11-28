import AgentCore
import Foundation
import FunctionContracts
import Gateway
import UI

extension VisionPerceptionAgent {
    public func bindUIExecution(_ consumer: GatewayOutputConsumer) async {
        uiExecution.consumer = consumer
        await island.bind(consumer: consumer, source: descriptor.id)
        await island.start()
    }

    func handleAlbum(_ value: AlbumInput, context: ProcessingContext) async throws -> AlbumReply {
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
        let result = try await consumer.callTool(envelope)
        if result.isCancellationOnly { throw CancellationError() }
        if result.isError {
            // take preserves the original storage/platform failure when the handler ran.
            _ = try await request.take()
            throw CameraIntentFailure.execution(result)
        }
        return try await request.take()
    }
}
