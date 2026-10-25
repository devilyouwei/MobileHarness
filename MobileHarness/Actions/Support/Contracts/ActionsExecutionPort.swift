import Foundation

public struct ActionExecutionDescriptor: Sendable {
    public enum ExecutionPolicy: Sendable {
        case direct
        case scheduled(channel: String)
    }
    public enum CallProtocol: String, Sendable { case action, tool }
    public enum DirectResultPolicy: Sendable { case completionOnly, returning }
    public let path: ActionIdentifier
    public let declaration: ActionDeclaration?
    public let displayName: String
    public let kind: ActionFunction.Kind
    public let protocols: Set<CallProtocol>
    public let executionPolicy: ExecutionPolicy
    public let directResultPolicy: DirectResultPolicy
    public init(
        path: ActionIdentifier, declaration: ActionDeclaration?, displayName: String,
        kind: ActionFunction.Kind, protocols: Set<CallProtocol>, executionPolicy: ExecutionPolicy,
        directResultPolicy: DirectResultPolicy
    ) {
        self.path = path
        self.declaration = declaration
        self.displayName = displayName
        self.kind = kind
        self.protocols = protocols
        self.executionPolicy = executionPolicy
        self.directResultPolicy = directResultPolicy
    }
}

/// Immutable descriptions only: neither handlers nor registry mutation escape through this view.
public struct ActionCatalogSnapshot: Sendable {
    public let revision: UUID
    public let entries: [ActionExecutionDescriptor]
    public init(revision: UUID, entries: [ActionExecutionDescriptor]) {
        self.revision = revision
        self.entries = entries
    }
    public func descriptor(for path: ActionIdentifier) throws -> ActionExecutionDescriptor {
        guard let found = entries.first(where: { $0.path == path }) else {
            throw ActionExecutionError.missingHandler(path)
        }
        return found
    }
}
public struct PreparedAction: Sendable {
    public let id: UUID
    public let revision: UUID
    public let descriptor: ActionExecutionDescriptor
    public let resources: Set<ResourceID>
    public let budget: ActionExecutionBudget
    public init(
        id: UUID, revision: UUID, descriptor: ActionExecutionDescriptor,
        resources: Set<ResourceID>, budget: ActionExecutionBudget
    ) {
        self.id = id
        self.revision = revision
        self.descriptor = descriptor
        self.resources = resources
        self.budget = budget
    }
}

/// App injects this port into Gateway. It carries no Agent, Skill or concrete registry.
public struct ActionsExecutionPort: Sendable {
    public let catalog: @Sendable () async throws -> ActionCatalogSnapshot
    public let prepare:
        @Sendable (FunctionInvocation, ActionExecutionDescriptor.CallProtocol) async throws -> PreparedAction
    public let execute: @Sendable (PreparedAction) async throws -> ActionCompletion
    public let discard: @Sendable (PreparedAction) async -> Void
    public init(
        catalog: @escaping @Sendable () async throws -> ActionCatalogSnapshot,
        prepare:
            @escaping @Sendable (FunctionInvocation, ActionExecutionDescriptor.CallProtocol) async throws ->
            PreparedAction,
        execute: @escaping @Sendable (PreparedAction) async throws -> ActionCompletion,
        discard: @escaping @Sendable (PreparedAction) async -> Void
    ) {
        self.catalog = catalog
        self.prepare = prepare
        self.execute = execute
        self.discard = discard
    }
}
