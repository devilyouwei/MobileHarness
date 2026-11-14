import AgentCore
import Foundation
import FunctionContracts
import StorageCore

/// Application Agent names; the framework only defines the identity value type.
extension AgentID {
    public static let speechPerception = AgentID(rawValue: "speechPerception")
    public static let visionPerception = AgentID(rawValue: "visionPerception")
    public static let photographer = AgentID(rawValue: "photographer")
    public static let writer = AgentID(rawValue: "writer")
    public static let memory = AgentID(rawValue: "memory")
    public static let applicationControl = AgentID(rawValue: "applicationControl")
    public static let assistant = AgentID(rawValue: "assistant")
}
/// Business communication schemas and freshness policy, assembled into the generic registry.
public enum AgentContracts {
    /// Role-owned local implementations are assembled here, never discovered by shared loaders.
    public static var localTools: [AgentLocalTool] {
        WriterLocalTools.declarations.map { AgentLocalTool(owner: .writer, declaration: $0) }
    }
    public static var localToolPaths: Set<String> {
        Set(localTools.map { $0.declaration.path.description })
    }

    public static var communication: CommunicationContracts {
        get throws {
            try CommunicationContracts(
                additional: AgentTaskSignal.contracts + [
                    CommunicationContract(
                        name: AgentTaskRequest.contract, kind: .observation, maximumBytes: 32768, startsNewWork: true,
                        validateMessage: { message in
                            guard let value = message.content(as: AgentTaskRequest.self) else {
                                throw CommunicationError.invalidPayload
                            }
                            try value.validate()
                        }),
                    CommunicationContract(
                        name: AgentTaskResponse.contract, kind: .observation, maximumBytes: 131072, startsNewWork: true,
                        validateMessage: { message in
                            if let response = message.content(as: AgentTaskResponse.self) {
                                try response.validate()
                                return
                            }
                            guard let signal = message.content(as: AgentTaskSignal.self),
                                signal.kind == .progress || signal.kind == .result
                            else {
                                throw CommunicationError.invalidPayload
                            }
                            try signal.validate()
                        }),
                    contract(PerceptionMessage.asrPartialContract, topic: PerceptionMessage.userInputTopic),
                    contract(PerceptionMessage.asrFinalContract, topic: PerceptionMessage.userInputTopic),
                    contract("sound.source"),
                    contract("vision.pose", maximumBytes: 262_144),
                ])
        }
    }
    private static func contract(
        _ name: String, topic: String? = nil, maximumBytes: Int = 16_384, startsNewWork: Bool = false
    ) -> CommunicationContract {
        CommunicationContract(
            name: name, kind: .observation, topic: topic, maximumBytes: maximumBytes,
            startsNewWork: startsNewWork,
            validateMessage: { message in
                guard let value = message.perception, value.contract == name else {
                    throw CommunicationError.invalidPayload
                }
                try value.validate()
            })
    }
}

/// A native function implemented inside its owning role, outside Gateway execution.
public struct AgentLocalTool: Equatable, Sendable {
    public let owner: AgentID
    public let declaration: ActionDeclaration
    public init(owner: AgentID, declaration: ActionDeclaration) {
        self.owner = owner
        self.declaration = declaration
    }
}

/// Immutable module-level schema contract; local declarations confer no execution permission.
public struct AgentFunctionCatalog: Equatable, Sendable {
    public let declarations: [ActionDeclaration]
    public let localTools: [AgentLocalTool]
    public init(declarations: [ActionDeclaration], localTools: [AgentLocalTool] = []) throws {
        guard !declarations.isEmpty, declarations.count <= 256, localTools.count <= 128,
            Set(declarations.map(\.path)).count == declarations.count,
            Set(localTools.map { $0.declaration.path }).count == localTools.count,
            Set(declarations.map(\.path)).isDisjoint(with: localTools.map { $0.declaration.path }),
            localTools.allSatisfy({ ActionIdentifier.validName($0.owner.rawValue) })
        else { throw AgentConfigurationError.invalidField("function declarations") }
        for declaration in declarations { try declaration.validate() }
        for tool in localTools { try tool.declaration.validate() }
        self.declarations = declarations.sorted { $0.path.description < $1.path.description }
        self.localTools = localTools.sorted { $0.declaration.path.description < $1.declaration.path.description }
    }

    func validateLocalTool(path: String, callType: String, owner: AgentID?) throws {
        guard let local = localTools.first(where: { $0.declaration.path.description == path }) else { return }
        guard callType == "tool", local.owner == owner else {
            throw AgentConfigurationError.invalidField("local tool ownership: " + path)
        }
    }

    func declaration(path: String, callType: String, owner: AgentID?) throws -> ActionDeclaration? {
        try validateLocalTool(path: path, callType: callType, owner: owner)
        return declarations.first { $0.path.description == path }
            ?? localTools.first { $0.declaration.path.description == path }?.declaration
    }
}
