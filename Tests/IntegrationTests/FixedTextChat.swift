import AgentCore
import Foundation
import ModelKit
import Synchronization

@testable import Agents

/// Test-only deterministic capability; production Assistant always requires an injected model.
struct FixedTextChat: ChatCapability {
    var text = "Test reply"
    var usage: ChatTokenUsage?
    var availability: CapabilityAvailability { .available }
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text(text))
        if let usage { try pair.emitter.yield(.usage(usage)) }
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
final class FixtureFactCell<Value: Sendable>: Sendable {
    private let memory: Mutex<Value>
    init(_ value: Value) { memory = Mutex(value) }
    func read() -> Value { memory.withLock { $0 } }
    func update(_ change: (inout Value) -> Void) { memory.withLock { change(&$0) } }
}
final class PublicStateFixtureOwner: Sendable {
    let camera: FixtureFactCell<FixtureCameraFact>
    init(ready: Bool = false) { camera = FixtureFactCell(FixtureCameraFact(enabled: ready, running: ready)) }
    func context() throws -> AgentStateContext {
        let context = AgentStateContext()
        try context.register(
            "actions.camera",
            source: ContainerContextSource { [self] in
                ContainerContextValue(camera.read())
            })
        try context.register("actions.robot", source: ContainerContextSource { ContainerContextValue(false) })
        for name in ["ui.navigation", "ui.camera", "ui.album"] {
            try context.register(name, source: ContainerContextSource { ContainerContextValue([String: String]()) })
        }
        return context
    }
}
func publicStateFixture() throws -> AgentStateContext { try PublicStateFixtureOwner().context() }
