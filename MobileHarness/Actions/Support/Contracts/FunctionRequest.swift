import Foundation

/// Resolved business address and parameters; scheduling remains outside the function contract.
public struct FunctionRequest: Equatable, Sendable {
    public let actionPath: ActionIdentifier
    public let parameters: [String: String]
    public init(actionPath: ActionIdentifier, parameters: [String: String] = [:]) {
        self.actionPath = actionPath
        self.parameters = parameters
    }
}

/// Immutable arguments, captured before effects. Attachments and credential/service objects stay out of this value.
public struct ActionInvocationSnapshot: Codable, Sendable, Equatable {
    public static let protocolID = "action.invocation.v1"
    public static let maximumBytes = 4 * 1024 * 1024
    public static let inlineBytes = 128 * 1024
    public let function: ActionIdentifier
    public let arguments: [String: String]?
    public let reference: String?
    public let encodedBytes: Int
    public var retainedBytes: Int {
        (arguments ?? [:]).reduce(function.description.utf8.count) { $0 + $1.key.utf8.count + $1.value.utf8.count }
    }
    public enum InvalidSnapshot: Error, Sendable { case invalidFunction, capacityExceeded, missingArchive }
    public init(_ request: FunctionRequest) throws {
        guard request.actionPath.isValid else { throw InvalidSnapshot.invalidFunction }
        function = request.actionPath
        arguments = request.parameters
        reference = nil
        encodedBytes = try JSONEncoder().encode(request.parameters).count + function.description.utf8.count
        guard request.parameters.count <= 128, encodedBytes <= Self.maximumBytes else {
            throw InvalidSnapshot.capacityExceeded
        }
    }
    private init(function: ActionIdentifier, arguments: [String: String]?, reference: String, encodedBytes: Int) {
        self.function = function
        self.arguments = arguments
        self.reference = reference
        self.encodedBytes = encodedBytes
    }
    public func archived(at reference: String) throws -> Self {
        guard UUID(uuidString: reference) != nil else { throw InvalidSnapshot.missingArchive }
        return Self(function: function, arguments: arguments, reference: reference, encodedBytes: encodedBytes)
    }
    private enum CodingKeys: String, CodingKey { case function, arguments, reference, encodedBytes }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        function = try fields.decode(ActionIdentifier.self, forKey: .function)
        encodedBytes = try fields.decode(Int.self, forKey: .encodedBytes)
        arguments = try fields.decodeIfPresent([String: String].self, forKey: .arguments)
        reference = try fields.decodeIfPresent(String.self, forKey: .reference)
        guard function.isValid, (1...Self.maximumBytes).contains(encodedBytes),
            (arguments != nil) != (reference != nil), reference.map({ UUID(uuidString: $0) != nil }) ?? true
        else {
            throw InvalidSnapshot.invalidFunction
        }
        if let arguments {
            guard try JSONEncoder().encode(arguments).count + function.description.utf8.count == encodedBytes else {
                throw InvalidSnapshot.capacityExceeded
            }
        }
    }
    public func restoring(from data: Data) throws -> Self {
        let original = try JSONDecoder().decode(Self.self, from: data)
        guard let reference, original.reference == nil, original.function == function,
            original.encodedBytes == encodedBytes
        else { throw InvalidSnapshot.missingArchive }
        return Self(function: function, arguments: original.arguments, reference: reference, encodedBytes: encodedBytes)
    }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(function, forKey: .function)
        try fields.encode(encodedBytes, forKey: .encodedBytes)
        if let reference {
            try fields.encode(reference, forKey: .reference)
        } else {
            try fields.encodeIfPresent(arguments, forKey: .arguments)
        }
    }
}
