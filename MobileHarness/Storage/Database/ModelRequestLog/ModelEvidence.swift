import Foundation

public struct ModelFailureDiagnostic: Codable, Sendable, Equatable {
    public let category: String
    public let code: String
    public let stage: String
    public let message: String
    public let details: [String: String]
    public let causes: [ModelFailureDiagnostic]
    public init(
        category: String, code: String, stage: String, message: String,
        details: [String: String] = [:], causes: [ModelFailureDiagnostic] = []
    ) {
        self.category = category
        self.code = code
        self.stage = stage
        self.message = message
        self.details = details
        self.causes = causes
    }
}

public struct ModelMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ModelTokenUsage: Codable, Sendable, Equatable {
    public let input: Int
    public let generated: Int
    public let total: Int
    public let cachedInput: Int?
    public let cacheWriteInput: Int?
    public init(
        input: Int, generated: Int, total: Int, cachedInput: Int? = nil, cacheWriteInput: Int? = nil
    ) {
        self.input = input
        self.generated = generated
        self.total = total
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
    }
}

public struct ModelToolCall: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case received, completed, failed, cancelled }
    public let id: String
    public let providerID: String
    public let name: String
    public let argumentsJSON: String
    public var state: State = .received
    public var output: String?
    public var error: String?
    public var failureDiagnostic: ModelFailureDiagnostic?
    public init(id: String, providerID: String, name: String, argumentsJSON: String) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct ModelGenerationRound: Codable, Sendable, Identifiable {
    public let id: String
    public let resultsJSON: String
    public init(id: String, resultsJSON: String) {
        self.id = id
        self.resultsJSON = resultsJSON
    }
}
