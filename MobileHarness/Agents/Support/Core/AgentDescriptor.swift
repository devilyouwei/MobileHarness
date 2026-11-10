/// Static role classification; it does not grant capabilities or select an execution policy.
public enum AgentCategory: String, Codable, Sendable {
    case perception
    case cognition
}

public struct AgentDescriptor: Sendable {
    public let category: AgentCategory
    public let id: AgentID
    public let name: String
    public let version: String
    public let inputs: Set<InputKind>
    public let outputs: Set<OutputKind>
    public let capabilities: CapabilityRegistry

    public init(
        category: AgentCategory, id: AgentID, name: String, version: String = "0.1.0", inputs: Set<InputKind>,
        outputs: Set<OutputKind>, capabilities: CapabilityRegistry = try! CapabilityRegistry()
    ) {
        self.category = category
        self.id = id
        self.name = name
        self.version = version
        self.inputs = inputs
        self.outputs = outputs
        self.capabilities = capabilities
    }
}
