import ModelKit

/// Resolves the current managed chat binding on every operation after settings changes.
public struct CurrentChatCapability: ChatCapability {
    public let models: ModelManager
    public init(models: ModelManager) { self.models = models }
    public var availability: CapabilityAvailability {
        get async {
            do { return try await models.availability(.chat) } catch {
                return .unavailable(reason: "Chat binding unavailable: \(String(describing: error).prefix(512))")
            }
        }
    }
    public var supportsToolCalls: Bool {
        get async {
            do { return await (try await models.get(.chat)).supportsToolCalls } catch { return false }
        }
    }
    public var supportsImages: Bool {
        get async {
            do { return await (try await models.get(.chat)).supportsImages } catch { return false }
        }
    }
    public func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let provider = try await models.get(.chat)
        return try await provider.chat(request)
    }
}
