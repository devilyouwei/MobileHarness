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
    var supportsToolCalls: Bool {
        get async {
            do { return await (try await models.get(.chat)).supportsToolCalls } catch { return false }
        }
    }
    var supportsImages: Bool {
        get async {
            do { return await (try await models.get(.chat)).supportsImages } catch { return false }
        }
    }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let provider = try await models.get(.chat)
        return try await provider.chat(request)
    }
}
