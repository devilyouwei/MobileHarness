import Foundation

/// One write to a variable that has a trigger. `new == nil` is a clear.
public struct AgentStateWrite: Sendable, Equatable {
    public let name: String
    public let old: String?
    public let new: String?
    public let note: String?
    public let source: AgentStateSource
    public let sessionID: String
    public let inputID: String
    public let decisionID: String?
    let wakeCondition: String?
    public init(
        name: String, old: String?, new: String?, note: String?, source: AgentStateSource, sessionID: String,
        inputID: String, decisionID: String?, wakeCondition: String? = nil
    ) {
        self.name = name
        self.old = old
        self.new = new
        self.note = note
        self.source = source
        self.sessionID = sessionID
        self.inputID = inputID
        self.decisionID = decisionID
        self.wakeCondition = wakeCondition
    }
}

/// What the writer does after a handler returns.
public enum AgentStateTriggerOutcome: Sendable, Equatable {
    /// The handler accepted the change; the variable table stores the value.
    case publish
    /// The handler owns the value's storage (such as the `task` goal record); nothing more is published.
    case handled
}

/// Behavior bound to a variable by trigger name. A throwing handler rejects the write: nothing is published and the
/// error reaches the writer unchanged.
public typealias AgentStateTriggerHandler = @Sendable (AgentStateWrite) async throws -> AgentStateTriggerOutcome

/// The handlers an Agent registers for the trigger names its `Agent.json` declares.
///
/// The set is fixed at construction and bounded by `AgentStateSchema.maximumDeclarations`. A handler is not reentrant:
/// a write that arrives while the same trigger is running is rejected with `triggerBusy`.
public actor AgentStateTriggers {
    private let handlers: [String: AgentStateTriggerHandler]
    private var running: Set<String> = []

    public init() { handlers = [:] }

    public init(_ handlers: [String: AgentStateTriggerHandler]) throws {
        guard handlers.count <= AgentStateSchema.maximumDeclarations,
            handlers.keys.allSatisfy({ AgentStateVariables.validName($0) })
        else { throw AgentStateError.invalidDeclaration }
        self.handlers = handlers
    }

    /// A declared trigger without a handler is a configuration error, reported at startup instead of at first write.
    public nonisolated func validate(schema: AgentStateSchema) throws {
        for case let name? in schema.declarations.values.map(\.trigger) where handlers[name] == nil {
            throw AgentStateError.unregisteredTrigger(name)
        }
    }

    /// Runs the handler bound to the variable, if any. Without one the write is simply published.
    public func apply(_ write: AgentStateWrite, schema: AgentStateSchema) async throws -> AgentStateTriggerOutcome {
        guard let trigger = schema.declarations[write.name]?.trigger else { return .publish }
        guard let handler = handlers[trigger] else { throw AgentStateError.unregisteredTrigger(trigger) }
        // Suspension inside the handler lets another caller in, which is why the running set rejects it.
        guard running.insert(trigger).inserted else { throw AgentStateError.triggerBusy(trigger) }
        defer { running.remove(trigger) }
        return try await handler(write)
    }
}
