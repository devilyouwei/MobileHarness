import AgentCore
import FunctionContracts
import Gateway

/// Scoped by the producer-bound consumer; child execution tasks inherit the result owner.
enum AgentToolFeedbackDelivery { @TaskLocal static var internalCompletion = false }

/// Native call adapter: native calls execute directly without Channel/wait; feedback crosses InputGateway.
struct ToolDispatcher: Sendable {
    let catalog: ActionCatalogSnapshot
    let executor: DirectExecutionDispatcher
    let input: InputGateway
    let resources: ResourceCoordinator?
    var admission: GatewayAdmission? = nil

    private static func executionAttachment(_ image: ImageInput?, sequence: UInt64) throws -> (any Sendable)? {
        guard let image else { return nil }
        guard image.sequence == sequence, let captured = image.capturedAt,
            captured.duration(to: .now) >= .zero, captured.duration(to: .now) < .milliseconds(750)
        else { throw CommunicationError.expired }
        return image.attachment
    }
    private static func executionAttachment(_ envelope: OutputEnvelope) throws -> (any Sendable)? {
        if let attachment = envelope.executionAttachment {
            guard envelope.roundID == nil, envelope.taskScope == nil, envelope.media == nil,
                envelope.inputMetadata.origin == .local
            else { throw CommunicationError.unauthorized }
            return attachment
        }
        return try executionAttachment(envelope.media, sequence: envelope.sequence)
    }
    func dispatch(_ call: ToolCall, envelope: OutputEnvelope, owner: ExecutionOwner) async throws -> ToolResponse? {
        let descriptor = catalog.entries.first(where: {
            $0.path.description == call.toolPath && $0.protocols.contains(.tool)
        })
        let result: ToolResponse?
        if let descriptor {
            do {
                try admission?.check()
                let completion = try await executor.execute(
                    FunctionInvocation(
                        tool: call.executionRequest, context: envelope.executionContext,
                        attachment: try Self.executionAttachment(envelope)), owner: owner)
                result = try ToolResponse.response(
                    completion,
                    policy: envelope.roundID != nil ? .returning : descriptor.directResultPolicy, callID: call.id)
            } catch {
                let report = ActionReport.failureReport(for: error)
                if !report.hasFailures { try Task.checkCancellation() }
                let completion = ActionCompletion.report(report)
                result = ToolResponse(
                    callID: call.id, value: report.failureDescription ?? ActionReport.description(for: error),
                    isError: true, failureCode: ToolResponse.failureCode(completion, isError: true),
                    completion: completion)
            }
        } else {
            result = ToolResponse(
                callID: call.id, value: "Unknown tool: \(call.toolPath)", isError: true, failureCode: .unknownTool)
        }
        guard let result else { return nil }
        if Task.isCancelled, result.completion?.hasExecutionFailure == true { return result }
        try Task.checkCancellation()
        if AgentToolFeedbackDelivery.internalCompletion { return result }
        if envelope.roundID == nil, descriptor?.directResultPolicy == .completionOnly { return result }
        let failure: String?
        do {
            let report = try await input.deliverToolResult(
                ToolResult(
                    callID: result.callID, value: result.value, isError: result.isError,
                    failureCode: result.failureCode?.rawValue, completion: result.completion?.agentValue,
                    roundID: envelope.roundID),
                owner: owner, envelope: envelope)
            failure = report.flatMap { $0.rejected.isEmpty ? nil : "Result delivery rejected: \($0.rejected)" }
        } catch {
            try Task.checkCancellation()
            failure = String(describing: error)
        }
        return ToolResponse(
            callID: result.callID, value: result.value, isError: result.isError, deliveryFailure: failure,
            failureCode: result.failureCode, completion: result.completion)
    }
}
