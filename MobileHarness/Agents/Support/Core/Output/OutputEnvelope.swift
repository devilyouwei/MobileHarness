import Foundation
@_exported import FunctionContracts

/// Source identity is attached by the runtime, never accepted from model output.
public struct OutputEnvelope: Sendable {
    public let resourceBindings: [String: String]
    public let context: ProcessingContext
    public let source: AgentID
    public let inputMetadata: InputMetadata
    public let inputID: String
    public let sessionID: String
    public let turn: AgentTurn?
    public let taskScope: AgentTaskScope?
    public let sequence: UInt64
    public let roundID: String?
    public let callID: String?
    public var schedulingID: String { roundID ?? taskScope?.id ?? inputID }
    public let output: AgentOutput
    public let media: ImageInput?
    public let executionAttachment: (any Sendable)?
    public let failure: AgentFailureDiagnostic?
    public init(
        source: AgentID, context: ProcessingContext, output: AgentOutput, sequence: UInt64 = 0, roundID: String? = nil,
        callID: String? = nil, taskScope: AgentTaskScope? = nil, failure: AgentFailureDiagnostic? = nil,
        media: ImageInput? = nil, executionAttachment: (any Sendable)? = nil, resourceBindings: [String: String] = [:]
    ) {
        if failure != nil {
            guard case .control(let value) = output, value.hasPrefix("agent.error:") else {
                preconditionFailure("Failure diagnostics require an Agent error control")
            }
        }
        self.resourceBindings = resourceBindings
        self.context = context
        self.media = media
        self.executionAttachment = executionAttachment
        self.failure = failure
        self.roundID = roundID
        self.callID = callID
        self.inputMetadata =
            context.provenance
            ?? InputMetadata(
                payload: .event("local.processing"), source: context.source, origin: .local,
                sequence: context.sequence, rootID: context.rootID, parentID: context.parentID,
                hops: context.hops, deadline: context.deadline, generation: context.generation)
        self.turn = context.turn
        self.taskScope = taskScope
        self.sequence = sequence
        self.source = source
        self.inputID = context.requestID
        self.sessionID = context.sessionID
        self.output = output
    }
}

extension OutputEnvelope {
    public func bindingResources(_ bindings: [String: String]) -> Self {
        .init(
            source: source, context: context, output: output, sequence: sequence, roundID: roundID, callID: callID,
            taskScope: taskScope, failure: failure, media: media, executionAttachment: executionAttachment,
            resourceBindings: bindings)
    }
}

extension ExecutionOwner {
    public init(agent: AgentID, incarnation: String, sessionID: String) {
        self.init(endpoint: agent.rawValue, incarnation: incarnation, sessionID: sessionID)
    }
    public var agent: AgentID { AgentID(rawValue: endpoint) }
}
