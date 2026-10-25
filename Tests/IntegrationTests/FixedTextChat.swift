import AgentCore
import Foundation
import ModelKit
import PlatformKit
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
    let application = FixtureFactCell(["scene": "active", "modelPreparation": "idle"])
    init(ready: Bool = false) { camera = FixtureFactCell(FixtureCameraFact(enabled: ready, running: ready)) }
    func context() throws -> AgentStateContext {
        let context = AgentStateContext()
        try AgentPlatformState.register(in: context, reading: FixedPlatformState())
        try context.register(
            "agents.application",
            source: ContainerContextSource { [self] in
                ContainerContextValue(application.read())
            })
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

/// Explicit synthetic native facts; shared workflow tests never sample the host device.
struct FixedPlatformState: PlatformStateReading {
    func snapshot(_ source: PlatformStateSource) throws -> Data {
        let fields: [String: Any]
        switch source {
        case .time:
            fields = ["localDateTime": "2026-10-25T12:00:00+08:00", "weekday": "Sunday", "timeZone": "Asia/Shanghai"]
        case .power: fields = ["batteryLevel": 0.75, "batteryState": "unplugged", "lowPowerMode": false]
        case .thermal: fields = ["state": "nominal"]
        case .network:
            fields = [
                "status": "unknown", "interfaces": [String](), "expensive": NSNull(), "constrained": NSNull(),
                "observedAt": NSNull(),
            ]
        case .permissions:
            fields = [
                "camera": "notDetermined", "microphone": "notDetermined", "photosAddOnly": "notDetermined",
                "photosReadWrite": "notDetermined", "bluetooth": "notDetermined",
            ]
        case .audio:
            fields = ["inputs": [String](), "outputs": [String](), "inputMuted": false, "interrupted": NSNull()]
        case .locale: fields = ["identifier": "en_US", "preferredLanguage": "en-US", "region": "US"]
        case .accessibility:
            fields = ["voiceOver": false, "reduceMotion": false, "closedCaptions": false, "monoAudio": false]
        }
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }
}
