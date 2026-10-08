import AgentCore
import Agents
import Foundation

/// Tests inspect the text-to-handle boundary without running a model or device.
actor SpeechRequestProbe {
    var requests: [String: String] = [:]
    func receive(_ message: AgentMessage) {
        if case .speechSynthesis(let request)? = message.perception {
            requests[request.audioID.uuidString] = request.text
        }
    }
    func text(_ id: String) -> String? { requests[id] }
    func restored(_ output: AgentOutput) -> AgentOutput {
        guard case .actionCall(let call) = output, let id = call.parameters["audioID"], let text = requests[id] else {
            return normalizeToolID(output)
        }
        return .actionCall(ActionCall(actionPath: call.actionPath, channel: call.channel, parameters: ["text": text]))
    }
    func restored(_ outputs: [AgentOutput]) -> [AgentOutput] { outputs.map(restored) }
}
func bindSpeechRequests(_ agent: AssistantAgent) async throws -> SpeechRequestProbe {
    let probe = SpeechRequestProbe()
    try await agent.bind(
        AgentMessaging { message, _, target in
            await probe.receive(message)
            return DeliveryReport(delivered: target.map { [$0] } ?? [])
        })
    return probe
}

/// Synthetic execution adapter for Agent-only tests. Integration round tests use the real Gateways.
struct FixtureGenerationOutputs: AsyncSequence {
    typealias Element = OutputEnvelope
    let agent: AssistantAgent
    func makeAsyncIterator() -> Iterator { Iterator(base: agent.outputs.makeAsyncIterator(), agent: agent) }
    struct Iterator: AsyncIteratorProtocol {
        var base: AsyncStream<OutputEnvelope>.Iterator
        let agent: AssistantAgent
        mutating func next() async throws -> OutputEnvelope? {
            while let envelope = await base.next() {
                if let roundID = envelope.roundID {
                    let payload: InputPayload?
                    switch envelope.output {
                    case .actionCall(let call):
                        let owner = ExecutionOwner(
                            agent: .assistant, incarnation: UUID(), sessionID: envelope.sessionID)
                        payload = .actionResult(
                            .init(
                                executionID: UUID(), owner: owner, path: call.actionPath,
                                causality: SignalCausality(envelope: envelope), status: .succeeded,
                                effect: .contractCompleted,
                                completion: .completed, callID: envelope.callID, roundID: roundID))
                    case .roundFinished:
                        payload = .roundResult(.init(roundID: roundID))
                    default: payload = nil
                    }
                    if let payload {
                        do {
                            try await agent.receive(
                                AgentInput(
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
