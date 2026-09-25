import AgentCore
import Foundation
import ModelKit

public struct DeliveryReport: Sendable {
    public let delivered: [AgentID]
    public let rejected: [AgentID: String]
}

public actor InputGateway {
    private let manager: AgentManager
    private let router: any SignalRouter
    private let recognition: (any SpeechRecognitionCapability)?
    public init(
        manager: AgentManager, router: any SignalRouter = LogicRouter(),
        recognition: (any SpeechRecognitionCapability)? = nil
    ) {
        self.manager = manager
        self.router = router
        self.recognition = recognition
    }

    /// Ordered live input still enters through the gateway; the caller owns session cancellation.
    public func openSpeechStream(sessionID: UUID, locale: String = "auto") async throws -> SpeechRecognitionSession {
        guard let recognition else { throw CapabilityError.unavailable("未配置语音识别能力") }
        return try await recognition.transcribe(
            SpeechRecognitionRequest(
                locale: locale, format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32),
                context: InferenceContext(conversationID: sessionID)))
    }

    /// Fan-out is best-effort; one rejected destination does not suppress delivery to others.
    public func submit(_ input: AgentInput, to target: AgentID? = nil) async throws -> DeliveryReport {
        let destinations: [AgentID]
        if let target { destinations = [target] } else { destinations = try await router.destinations(for: input) }
        var delivered: [AgentID] = []
        var rejected: [AgentID: String] = [:]
        var seen: Set<AgentID> = []
        for id in destinations where seen.insert(id).inserted {
            do {
                let agent = try await manager.agent(id)
                guard agent.descriptor.inputs.contains(input.payload.kind) else { throw HarnessError.unsupportedInput }
                try await agent.receive(input)
                delivered.append(id)
            } catch { rejected[id] = String(describing: error) }
        }
        return DeliveryReport(delivered: delivered, rejected: rejected)
    }
}
