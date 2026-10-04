import AgentCore
import Agents
import Foundation

/// The host owns device source names and media admission deadlines.
enum MediaInputAdapter {
    static let externalSources: Set<String> = ["user", "runtime", "phone.microphone", "phone.camera"]
    static func audio(_ audio: AudioInput, sessionID: UUID) -> AgentInput {
        let id = UUID()
        let payload = InputPayload.audio(audio)
        return AgentInput(
            id: id, sessionID: sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "phone.microphone", rootID: id, deadline: .now.advanced(by: .seconds(60))))
    }
    static func image(_ image: ImageInput, sessionID: UUID) -> AgentInput {
        let id = UUID()
        let payload = InputPayload.image(image)
        return AgentInput(
            id: id, sessionID: sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "phone.camera", rootID: id, deadline: .now.advanced(by: .seconds(1))))
    }
}
