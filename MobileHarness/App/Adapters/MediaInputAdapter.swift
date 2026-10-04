import AgentCore
import Agents
import Foundation
import ModelKit
import Types

/// Composition-only adapter keeps ModelKit and native camera types out of AgentCore.
nonisolated struct CameraImageAttachment: ImageAttachment {
    let image: ImageFrame
    static func resolve(_ input: ImageInput) throws -> ImageFrame {
        switch input.content {
        case .rgb(let rgb): return try ImageFrame(width: input.width, height: input.height, rgb: rgb)
        case .attachment(let attachment):
            guard let sample = attachment as? SampledImageAttachment,
                let value = sample.source as? CameraImageAttachment,
                value.image.width == input.width, value.image.height == input.height,
                value.image.native?.rotation == input.rotation
            else { throw ImageInputError.invalidFrame }
            return value.image
        }
    }
}

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
