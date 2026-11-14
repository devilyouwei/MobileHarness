import AgentCore
import Foundation
import StorageCore

@testable import Agents

/// Tests inspect the text-to-handle boundary without running a model or device.
actor SpeechRequestProbe: AssistantSpeechProducing {
    var requests: [String: String] = [:]
    var beforePrepare: (@Sendable () async throws -> Void)?
    var prepared: (@Sendable (String, String) async -> Void)?
    init(
        beforePrepare: (@Sendable () async throws -> Void)? = nil,
        prepared: (@Sendable (String, String) async -> Void)? = nil
    ) {
        self.beforePrepare = beforePrepare
        self.prepared = prepared
    }
    func prepare(text: String, input: AgentInput) async throws -> String {
        try await beforePrepare?()
        let id = UUID().uuidString
        requests[id] = text
        await prepared?(id, text)
        return id
    }
    func cancel(audioID: String, input: AgentInput) {}
    func cancel(input: AgentInput) {}
    func stop() {}
    func text(_ id: String) -> String? { requests[id] }
    func restored(_ output: AgentOutput) -> AgentOutput {
        guard case .actionCall(let call) = output, let id = call.parameters["audioID"], let text = requests[id] else {
            return normalizeToolID(output)
        }
        return .actionCall(ActionCall(actionPath: call.actionPath, channel: call.channel, parameters: ["text": text]))
    }
    func restored(_ outputs: [AgentOutput]) -> [AgentOutput] { outputs.map(restored) }
}
private protocol FixtureSpeechBindable: Sendable {
    func bindSpeechOutput(_ value: any AssistantSpeechProducing) async throws
}
extension AssistantChatWorker: FixtureSpeechBindable {}
func bindSpeechRequests(_ agent: any Agent) async throws -> SpeechRequestProbe {
    let probe = SpeechRequestProbe()
    guard let target = agent as? any FixtureSpeechBindable else { throw HarnessError.unsupportedInput }
    try await target.bindSpeechOutput(probe)
    try bindFixtureCommunications(
        agent, port: AgentMessaging { _, _, target in DeliveryReport(delivered: target.map { [$0] } ?? []) })
    return probe
}

/// Synthetic execution adapter for Agent-only tests. Integration round tests use the real Gateways.
struct FixtureGenerationOutputs: AsyncSequence {
    typealias Element = OutputEnvelope
    let agent: any Agent
    let observer: @Sendable (OutputEnvelope) async -> Void
    let actionCompletion: @Sendable (ActionCall) -> (AgentActionCompletion, ActionResult.Failure?)
    init(
        agent: any Agent, observer: @escaping @Sendable (OutputEnvelope) async -> Void = { _ in },
        actionCompletion: @escaping @Sendable (ActionCall) -> (AgentActionCompletion, ActionResult.Failure?) = {
            _ in (.completed, nil)
        }
    ) {
        self.agent = agent
        self.observer = observer
        self.actionCompletion = actionCompletion
    }
    func makeAsyncIterator() -> Iterator {
        Iterator(
            base: fixtureOutputs(agent).makeAsyncIterator(), agent: agent, observer: observer,
            actionCompletion: actionCompletion)
    }
    struct Iterator: AsyncIteratorProtocol {
        var base: AsyncStream<OutputEnvelope>.Iterator
        let agent: any Agent
        let observer: @Sendable (OutputEnvelope) async -> Void
        let actionCompletion: @Sendable (ActionCall) -> (AgentActionCompletion, ActionResult.Failure?)
        mutating func next() async throws -> OutputEnvelope? {
            while let envelope = await base.next() {
                await observer(envelope)
                if case .communication(let action) = envelope.output {
                    guard action.target != nil else { continue }
                    let payload = InputPayload.communicationReceipt(
                        .init(
                            callID: action.id,
                            report: DeliveryReport(delivered: action.target.map { [$0] } ?? []),
                            owner: ExecutionOwner(
                                agent: envelope.source, incarnation: UUID().uuidString,
                                sessionID: envelope.sessionID),
                            causality: SignalCausality(envelope: envelope)))
                    try await agent.receive(
                        AgentInput(
                            id: UUID().uuidString,
                            sessionID: envelope.sessionID, payload: payload,
                            metadata: InputMetadata(
                                payload: payload, source: "runtime", origin: .runtime,
                                rootID: UUID().uuidString)))
                    continue
                }
                if let roundID = envelope.roundID {
                    let payload: InputPayload?
                    switch envelope.output {
                    case .actionCall(let call):
                        let (completion, failure) = actionCompletion(call)
                        let owner = ExecutionOwner(
                            agent: envelope.source, incarnation: UUID().uuidString,
                            sessionID: envelope.sessionID)
                        payload = .actionResult(
                            .init(
                                executionID: UUID().uuidString, owner: owner, path: call.actionPath,
                                causality: SignalCausality(envelope: envelope),
                                status: failure == nil ? .succeeded : .failed,
                                effect: failure == nil ? .contractCompleted : .unknown,
                                completion: completion, failure: failure,
                                callID: envelope.callID, roundID: roundID))
                    case .roundFinished:
                        payload = .roundResult(.init(roundID: roundID))
                    default: payload = nil
                    }
                    if let payload {
                        do {
                            try await agent.receive(
                                AgentInput(
                                    id: UUID().uuidString,
                                    sessionID: envelope.sessionID, payload: payload,
                                    metadata: InputMetadata(
                                        payload: payload, source: "runtime", origin: .runtime,
                                        rootID: envelope.inputMetadata.rootID, parentID: envelope.inputID),
                                    turn: envelope.turn))
                        } catch CommunicationError.unauthorized {
                            // A failed producer can leave an already-emitted prefix for inspection.
                            guard case .actionCall = envelope.output else { throw CommunicationError.unauthorized }
                        }
                    }
                    if case .roundFinished = envelope.output { continue }
                }
                return envelope
            }
            return nil
        }
    }
}
