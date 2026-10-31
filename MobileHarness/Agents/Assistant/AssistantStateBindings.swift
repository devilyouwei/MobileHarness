import AgentCore
import Foundation
import FunctionContracts

/// Assistant's context policy. Producers and other consumers retain the complete State contract.
public enum AssistantStateBindings {
    public typealias ReadState = @Sendable (String) async throws -> any Encodable & Sendable
    private struct Selection: Sendable {
        let path: String
        let fields: [String]
    }
    private static let selections: [String: Selection] = [
        "agents.applicationcontrol": .init(path: "agents.applicationcontrol", fields: ["modelPreparation"]),
        "actions.camera": .init(
            path: "actions.camera",
            fields: [
                "enabled", "running", "selectedFacing", "busy", "needsSettings", "displayedMediaID", "savedMediaID",
                "problem",
            ]),
        "actions.robot": .init(
            path: "actions.robot",
            fields: [
                "connected", "controlAvailable", "phase", "jogging", "tracking", "positionsCounts",
                "feedbackAgeSeconds",
                "feedbackFresh", "trackingTargetCounts", "problem",
            ]),
        "actions.robot.motion": .init(path: "actions.robot.motion", fields: ["targetCounts"]),
        "ui.navigation": .init(
            path: "ui.navigation", fields: ["path", "phase", "current", "overlay", "content"]),
        "ui.camera": .init(path: "ui.camera", fields: ["enabled", "visible", "busy", "facing", "needsSettings"]),
        "ui.album": .init(path: "ui.album", fields: ["content", "loadedCount", "hasMore", "operation"]),
        "ui.home.expression": .init(
            path: "ui.home.expression", fields: ["base", "effective", "overridden", "transitioning", "loading"]),
        "platform.system.time": .init(path: "platform.system.time", fields: ["localDateTime", "weekday", "timeZone"]),
        "platform.system.power": .init(
            path: "platform.system.power", fields: ["lowPowerMode", "batteryLevel", "batteryState"]),
        "platform.system.thermal": .init(path: "platform.system.thermal", fields: ["state"]),
        "platform.system.network": .init(
            path: "platform.system.network", fields: ["status", "interfaces", "expensive", "constrained"]),
        "platform.system.permissions": .init(
            path: "platform.system.permissions",
            fields: ["camera", "photosAddOnly", "photosReadWrite", "microphone", "bluetooth"]),
        "platform.system.audio": .init(
            path: "platform.system.audio", fields: ["inputs", "outputs", "inputMuted", "interrupted"]),
        "platform.system.locale": .init(
            path: "platform.system.locale", fields: ["identifier", "preferredLanguage", "region"]),
        "platform.system.accessibility": .init(
            path: "platform.system.accessibility", fields: ["voiceOver", "reduceMotion", "closedCaptions", "monoAudio"]),
    ]
    public static var sourceNames: [String] {
        selections.keys.sorted()
    }

    public static func register(in context: AgentStateContext, names: [String] = sourceNames, read: @escaping ReadState)
        throws
    {
        for name in names {
            guard sourceNames.contains(name) else { throw ContainerContextError.missing }
            try context.register(
                name,
                source: ContainerContextSource {
                    try await snapshot(name, read: read)
                })
        }
    }
    /// Decode only facts. Runtime, diagnostic health, metadata and failure history cannot enter this view.
    private struct Node: Decodable {
        let path: String
        let business: [String: AgentStateSnapshot.Value]
        let readFailure: String?
    }
    private static func snapshot(_ name: String, read: ReadState) async throws -> ContainerContextValue<
        [String: AgentStateSnapshot.Value]
    > {
        guard let selection = selections[name] else { throw ContainerContextError.missing }
        let raw = try await read(selection.path)
        let data = try JSONEncoder().encode(raw)
        guard data.count <= 256 * 1024 else { throw ContainerContextError.capacityExceeded }
        let node = try JSONDecoder().decode(Node.self, from: data)
        try Task.checkCancellation()
        guard node.path == selection.path else { throw ContainerContextError.invalidSnapshot }
        guard node.readFailure == nil else { return .init(availability: .unknown) }
        let facts = Dictionary(
            uniqueKeysWithValues: selection.fields.map {
                ($0, selectedValue(node.business[$0] ?? .unknown, field: $0))
            })
        return .init(facts, availability: facts.values.contains { $0 != .unknown } ? .available : .unknown)
    }
    private static func selectedValue(_ value: AgentStateSnapshot.Value, field: String) -> AgentStateSnapshot.Value {
        switch value {
        case .object(let fields) where field == "current":
            return .object(
                Dictionary(
                    uniqueKeysWithValues: ["page", "itemID"].map { key in
                        let item = fields[key] ?? .unknown
                        if case .text = item { return (key, item) }
                        return (key, .unknown)
                    }))
        case .object(let fields) where field == "targetCounts":
            return .object(
                Dictionary(
                    uniqueKeysWithValues: (1...6).map { motor in
                        let key = String(motor)
                        let item = fields[key] ?? .unknown
                        if case .count = item { return (key, item) }
                        return (key, .unknown)
                    }))
        case .object, .array: return .unknown
        case .text, .flag, .count, .unsigned, .number, .integers, .texts, .unknown: return value
        }
    }
}
