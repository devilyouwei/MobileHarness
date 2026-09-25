import ModelKit

/// Test-only deterministic capability; production Assistant always requires an injected model.
struct FixedTextChat: ChatCapability {
    var text = "Test reply"
    var availability: CapabilityAvailability { .available }
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text(text))
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}
