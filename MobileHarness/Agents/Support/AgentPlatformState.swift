import AgentCore
import Foundation
import PlatformKit

/// Adapt neutral native facts into the model-context envelope; no native observation is started here.
public enum AgentPlatformState {
    public static let sourceNames = PlatformStateSource.allCases.map { "platform.\($0.rawValue)" }.sorted()
    public static func register(in context: AgentStateContext, reading reader: any PlatformStateReading) throws {
        for source in PlatformStateSource.allCases {
            try context.register(
                "platform.\(source.rawValue)",
                source: ContainerContextSource(encoded: {
                    let data = try await reader.snapshot(source)
                    guard data.count <= 8192 else { throw ContainerContextError.capacityExceeded }
                    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { throw ContainerContextError.invalidSnapshot }
                    return try JSONSerialization.data(
                        withJSONObject: ["availability": "available", "value": value], options: [.sortedKeys])
                }))
        }
    }
}
