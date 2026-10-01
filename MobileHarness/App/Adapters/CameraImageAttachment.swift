import AgentCore
import ModelKit

/// Composition-only adapter keeps ModelKit and native camera types out of AgentCore.
nonisolated struct CameraImageAttachment: ImageAttachment {
    let image: ImageFrame
    static func resolve(_ input: ImageInput) throws -> ImageFrame {
        switch input.content {
        case .rgb(let rgb): return try ImageFrame(width: input.width, height: input.height, rgb: rgb)
        case .sampled(_, let attachment):
            guard let value = attachment as? CameraImageAttachment,
                value.image.width == input.width, value.image.height == input.height,
                value.image.native?.rotation == input.rotation
            else { throw ImageInputError.invalidFrame }
            return value.image
        }
    }
}
