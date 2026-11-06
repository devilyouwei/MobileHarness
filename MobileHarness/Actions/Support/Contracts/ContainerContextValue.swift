import Foundation

public enum ContextAvailability: String, Codable, Sendable { case unknown, available, unavailable }
public struct ContainerContextValue<Value: Encodable & Sendable>: Encodable, Sendable {
    public let availability: ContextAvailability
    public let value: Value?
    public init(_ value: Value? = nil, availability: ContextAvailability = .available) {
        self.availability = availability
        self.value = value
    }
    private enum CodingKeys: String, CodingKey { case availability, value }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(availability, forKey: .availability)
        try fields.encode(value, forKey: .value)
    }
}

/// Request-only immutable media, excluded from ordinary JSON state inspection and durable audit bytes.
public struct ContextImage: Sendable {
    public let id: String
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let data: Data
    public init(id: String, mimeType: String = "image/jpeg", width: Int, height: Int, data: Data) {
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
    public init(facts: Data, revision: UInt64 = 0, images: [ContextImage] = []) {
        self.facts = facts
        self.revision = revision
        self.images = images
    }
}
public struct PreviewImageID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard rawValue.hasPrefix("preview_"), UUID(uuidString: String(rawValue.dropFirst(8))) != nil else { return nil }
        self.rawValue = rawValue
    }
}
