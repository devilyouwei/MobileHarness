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
    static func bindings(_ loaded: [String]) throws -> [AgentConfigurations.Binding] {
        var bindings: [AgentConfigurations.Binding] = []
        for id in loaded {
            for b in try AgentConfigurations.skill(id).functions {
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
}
