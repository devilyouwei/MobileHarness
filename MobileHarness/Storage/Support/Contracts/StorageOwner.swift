public struct StorageOwner: Sendable, Hashable {
    public let namespace: String
    public let source: String
    public let session: String
    public let input: String

    public init(namespace: String, source: String, session: String, input: String) {
        self.namespace = namespace
        self.source = source
        self.session = session
        self.input = input
    }
}
