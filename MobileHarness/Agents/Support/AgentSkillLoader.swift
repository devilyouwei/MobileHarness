import AgentCore
import Foundation

/// Stateless atomic composition of immutable Skill resources and canonical function grants.
public enum AgentSkillLoader {
    public static func expand(_ ids: [String]) throws -> [String] {
        var result: [String] = []
        func visit(_ id: String, path: [String]) throws {
            guard path.count < 8, !path.contains(id) else {
                throw AgentConfigurationError.invalidField("Skill dependency cycle/depth")
            }
            if result.contains(id) { return }
            let skill = try AgentConfigurations.skill(id)
            for dependency in skill.dependencies { try visit(dependency, path: path + [id]) }
            guard result.count < 16 else { throw CommunicationError.capacityExceeded }
            result.append(id)
        }
        for id in ids { try visit(id, path: []) }
        return result
    }
    public static func useStates(_ loaded: [String]) throws -> [String] {
        try Set(loaded.flatMap { try AgentConfigurations.skill($0).useStates }).sorted()
    }
    static func bindings(_ loaded: [String]) throws -> [AgentConfigurations.Binding] {
        var bindings: [AgentConfigurations.Binding] = []
        for id in loaded {
            for b in try AgentConfigurations.skill(id).useActions {
                if let existing = bindings.first(where: { $0.path == b.path }) {
                    guard existing == b else { throw GenerationError.duplicateAlias }
                } else {
                    bindings.append(b)
                }
            }
        }
        return bindings
    }
    public static func registry(_ loaded: [String], fixed: CapabilityRegistry) throws -> CapabilityRegistry {
        let selected = try AgentConfigurations.registry(bindings(loaded))
        return try CapabilityRegistry(
            actions: selected.actions, tools: selected.tools,
            channels: selected.channels, internalActions: fixed.internalActions,
            internalTools: fixed.internalTools)
    }
    /// Actual UTF-8 prompt cost; shared/base bindings are counted only once.
    static func nonBaseBytes(_ loaded: [String], base: [String]) throws -> Int {
        let baseRegistry = try AgentConfigurations.registry(bindings(base))
        let allRegistry = try AgentConfigurations.registry(bindings(loaded))
        let instructionBytes = try loaded.filter { !base.contains($0) }.reduce(0) {
            try $0 + AgentConfigurations.skillInstructions($1).utf8.count
        }
        let actionBytes = max(
            0,
            try CapabilityContextBuilder.catalog(allRegistry).utf8.count
                - CapabilityContextBuilder.catalog(baseRegistry).utf8.count)
        let baseTools = Set(baseRegistry.tools.map(\.path))
        let toolBytes = try allRegistry.tools.filter { !baseTools.contains($0.path) }.reduce(0) { bytes, tool in
            try bytes + (tool.definition.map { try JSONEncoder().encode($0).count } ?? 0)
        }
        return instructionBytes + actionBytes + toolBytes
    }

}
