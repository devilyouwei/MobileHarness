import AgentCore
import Agents

/// Tests inspect the text-to-handle boundary without running a model or device.
actor SpeechRequestProbe {
    var requests: [String: String] = [:]
    func receive(_ message: AgentMessage) {
        if case .speechSynthesis(let request) = message { requests[request.audioID.uuidString] = request.text }
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
