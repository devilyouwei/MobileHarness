import AgentCore
import Foundation

/// Bundled Agent policy is read once per instance; no source-path or hard-coded registry fallback.
public enum AgentConfigurations {
    public static func load(named name: String) throws -> AgentConfiguration {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
            let url = Bundle.module.url(forResource: "\(name).agent", withExtension: "json")
        else { throw AgentConfigurationError.resourceMissing(name) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 65_537) ?? Data()
        return try AgentConfiguration(data: data)
    }
}
