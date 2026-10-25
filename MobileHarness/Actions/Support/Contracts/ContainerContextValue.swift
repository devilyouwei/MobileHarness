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
