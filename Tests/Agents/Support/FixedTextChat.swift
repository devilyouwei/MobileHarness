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
    var business: [String: PlatformStateSnapshot.Value] {
        [
            "enabled": .flag(enabled), "perceptionEnabled": .flag(false),
            "lensOwner": enabled ? .text("capture") : .unknown,
            "busy": .flag(busy), "needsSettings": .flag(needsSettings),
            "displayedPreviewID": displayedMediaID.map { .text($0) } ?? .unknown,
            "savedMediaID": savedMediaID.map { .text($0) } ?? .unknown,
        ]
    }
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
        try FixedPlatformState.register(in: context, camera: { [camera] in camera.read() })
        try context.register(
            "agents.applicationcontrol",
            source: ContainerContextSource { [self] in
                ContainerContextValue(application.read())
            })
        try context.register(
            "actions.camera",
            source: ContainerContextSource { [self] in
                ContainerContextValue(camera.read().business)
            })
        try context.register(
            "agents.writer", source: ContainerContextSource { ContainerContextValue(["phase": "idle"]) })
        try context.register("actions.robot", source: ContainerContextSource { ContainerContextValue(false) })
        try context.register(
            "actions.robot.motion", source: ContainerContextSource { ContainerContextValue([String: String]()) })
        for name in ["ui.navigation", "ui.camera", "ui.album", "ui.home.expression", "ui.windows", "ui.island"] {
            try context.register(name, source: ContainerContextSource { ContainerContextValue([String: String]()) })
        }
        return context
    }
}
func publicStateFixture() throws -> AgentStateContext { try PublicStateFixtureOwner().context() }

/// Explicit synthetic native facts; shared workflow tests never sample the host device.
struct FixedPlatformState: PlatformStateReading {
    nonisolated static var sourceNames: [String] {
        PlatformStateSource.allCases.map { "platform.system." + $0.rawValue }.sorted()
    }
    nonisolated static func register(
        in context: AgentStateContext, camera: @escaping @Sendable () -> FixtureCameraFact = { FixtureCameraFact() }
    ) throws {
        try context.registerMedia(
            "actions.camera.preview",
            read: { _ in
                let id = camera().displayedMediaID
                return .init(
                    facts: try JSONEncoder().encode(["latestPreviewID": id]),
                    images: id.map { [.init(id: $0, width: 1, height: 1, data: Data([1]))] } ?? [])
            }, reset: { _ in })
        try AssistantStateBindings.register(in: context, names: ["platform.vision.camera"]) { _ in
            let value = camera()
            return PlatformStateSnapshot(
                path: "platform.vision.camera",
                business: [
                    "running": .flag(value.running), "phase": .text(value.running ? "running" : "stopped"),
                    "facing": .text(value.selectedFacing),
                ])
        }
        try AssistantStateBindings.register(in: context, names: sourceNames) { path in
            guard let raw = path.split(separator: ".").last,
                let source = PlatformStateSource(rawValue: String(raw))
            else { throw ContainerContextError.missing }
            let data = try await FixedPlatformState().snapshot(source)
            let facts = try JSONDecoder().decode([String: PlatformStateSnapshot.Value].self, from: data)
            return PlatformStateSnapshot(path: path, business: facts)
        }
    }
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
