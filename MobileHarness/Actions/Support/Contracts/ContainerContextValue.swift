import Foundation

/// A State source's meaningful value. An absent value encodes as null and is omitted from the model context.
public struct ContainerContextValue<Value: Encodable & Sendable>: Encodable, Sendable {
    public let value: Value?
    public init(_ value: Value? = nil) { self.value = value }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Request-only immutable media, excluded from ordinary JSON state inspection and durable audit bytes.
public struct ContextImage: Sendable {
    public let resourceScope: String?
    public let source: String?
    public let id: String
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let data: Data
    public init(
        id: String, mimeType: String = "image/jpeg", width: Int, height: Int, data: Data, source: String? = nil,
        resourceScope: String? = nil
    ) {
        self.resourceScope = resourceScope
        self.source = source
        self.id = id
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.data = data
    }
}
public struct MultimodalContextSnapshot: Sendable {
    public let facts: Data
    public let revision: UInt64
    public let images: [ContextImage]
    public let resourceScope: String?
    public let resourceBindings: [String: String]
    public init(
        facts: Data, revision: UInt64 = 0, images: [ContextImage] = [], resourceScope: String? = nil,
        resourceBindings: [String: String] = [:]
    ) {
        self.facts = facts
        self.revision = revision
        self.images = images
        self.resourceScope = resourceScope
        self.resourceBindings = resourceBindings
    }
}
