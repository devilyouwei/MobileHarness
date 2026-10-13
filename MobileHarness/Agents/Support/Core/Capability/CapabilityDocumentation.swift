/// Author-authored usage metadata. It does not convert arguments or enforce action value constraints.
public struct CapabilityDocumentation: Decodable, Sendable {
    public let doc: String
    public let parameters: [Parameter]

    public struct Parameter: Decodable, Sendable {
        public let name: String
        public let valueType: ValueType
        public let required: Bool
        public let description: String
        public let constraints: String
    }

    /// Intended type after parsing inside the Action; transport values remain strings.
    public enum ValueType: String, Decodable, Sendable {
        case string, integer, number, boolean
    }

}
