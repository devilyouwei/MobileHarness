import ModelKit
import ModelKitRuntime

/// Resolves the current managed chat binding on every operation after settings changes.
struct CurrentChatCapability: ChatCapability {
    let models: ModelManager
    var availability: CapabilityAvailability {
        get async {
            do { return try await models.availability(.chat) } catch { return .unavailable(reason: "对话模型暂不可用") }
        }
    }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let provider = try await models.get(.chat)
        return try await provider.chat(request)
    }
}
