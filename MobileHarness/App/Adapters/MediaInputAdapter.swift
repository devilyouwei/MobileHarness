import AgentCore
import Agents
import Foundation
import Storage

/// The host owns device source names and media admission deadlines.
enum MediaInputAdapter {
    static let externalSources: Set<String> = [
        "user", "runtime", "phone.microphone", "phone.camera", ModelResourceObservation.source,
        ModelResourceHostFailure.source, AppEnvironmentFact.source,
    ]
    static func audio(_ audio: AudioInput, sessionID: String) throws -> AgentInput {
        let id = UUID().uuidString
        let payload = InputPayload.audio(audio)
        return AgentInput(
            id: id, sessionID: sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "phone.microphone", rootID: id, deadline: .now.advanced(by: .seconds(60))))
    }
    static func image(_ image: ImageInput, sessionID: String) throws -> AgentInput {
        let id = UUID().uuidString
        let payload = InputPayload.image(image)
        return AgentInput(
            id: id, sessionID: sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "phone.camera", rootID: id, deadline: .now.advanced(by: .seconds(1))))
    }
}
