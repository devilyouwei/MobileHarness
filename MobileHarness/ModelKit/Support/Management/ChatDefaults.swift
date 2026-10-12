import Foundation
import ModelKit
import ModelKitOpenAI
@_spi(ModelAssembly) import ModelKitRuntime

#if !targetEnvironment(simulator)
    import ModelKitGemma4
#endif

extension ModelKitDefaults {
    @available(iOS 27, macOS 27, *)
    static func chatRegistration(resources: URL, configuration: OpenAIChatConfiguration?) throws
        -> ModelRegistration
    {
        try ModelRegistration(
            id: ModelID("chat"), capabilities: [.chat], memoryPolicy: .releaseWhenIdle,
            artifactID: configuration == nil ? "gemma4-e2b" : nil
        ) { context in
            if let configuration {
                return ProvidedCapabilities(chat: try OpenAIChat(context: context, configuration: configuration))
            }
            #if targetEnvironment(simulator)
                return ProvidedCapabilities(chat: UnsupportedChat())
            #else
                let model = try Gemma4Chat(context: context, artifacts: resources.appendingPathComponent("Gemma4"))
                return ProvidedCapabilities(warmup: { try await model.warmup() }, chat: model)
            #endif
        }
    }

}

#if targetEnvironment(simulator)
    private struct UnsupportedChat: ChatCapability {
        var availability: CapabilityAvailability { .unavailable(reason: "Gemma 4 CoreAI requires a physical device") }
        func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
            throw CapabilityError.unavailable("Gemma 4 CoreAI requires a physical device")
        }
    }

#endif
