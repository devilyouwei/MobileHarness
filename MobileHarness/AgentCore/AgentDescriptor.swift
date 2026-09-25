public struct AgentDescriptor: Sendable {
    public let id: AgentID
    public let name: String
    public let version: String
    public let inputs: Set<InputKind>
    public let outputs: Set<OutputKind>
    public let capabilities: CapabilityRegistry

    public init(
        id: AgentID, name: String, version: String = "0.1.0", inputs: Set<InputKind>,
        outputs: Set<OutputKind>, capabilities: CapabilityRegistry = try! CapabilityRegistry()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.inputs = inputs
        self.outputs = outputs
        self.capabilities = capabilities
    }
}
