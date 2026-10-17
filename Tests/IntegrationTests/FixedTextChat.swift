import AgentCore
import Agents
import Foundation
import ModelKit
import StorageState

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

struct FixtureCameraFact: Codable, Sendable {
    var enabled = false
    var running = false
    var selectedFacing = "front"
    var busy = false
    var needsSettings = false
    var displayedMediaID: String?
    var savedMediaID: String?
}
final class PublicStateFixtureOwner: Sendable {
    let scope: StateScope
    let camera: StateWriter<PublishedState<FixtureCameraFact>>
    init(_ storage: StateContainer, ready: Bool = false) throws {
        scope = try storage.makeScope()
        camera = try scope.register(
            StateKey("camera"), initial: PublishedState(FixtureCameraFact(enabled: ready, running: ready)))
        _ = try scope.register(StateKey<PublishedState<Bool>>("robot"), initial: PublishedState(false))
    }
}
func publicStateFixture() throws -> AgentStateContext {
    let storage = StateContainer()
    let owner = try PublicStateFixtureOwner(storage)
    return try AgentStateContext(storage: storage, agent: .assistant, retainingPublishers: owner)
}
