import AgentCore
import Foundation

/// Bundled model catalog and communication policy; code-owned internal grants are assembled by each Agent.
public enum AgentConfigurations {
    public static func load(named name: String) throws -> AgentConfiguration {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
            let url = Bundle.module.url(forResource: "\(name).agent", withExtension: "json")
        else { throw AgentConfigurationError.resourceMissing(name) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 65_537) ?? Data()
        return try AgentConfiguration(contracts: AgentContracts.communication, data: data)
    }
}
