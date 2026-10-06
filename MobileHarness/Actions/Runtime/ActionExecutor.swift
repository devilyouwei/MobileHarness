import Foundation

public struct ActionExecutor: Sendable {
    public static let defaultTimeout: Duration = .seconds(30)
    private let registry: ActionRegistry
    public init(registry: ActionRegistry) { self.registry = registry }
    @discardableResult
    public func execute(_ invocation: ActionInvocation) async throws -> ActionCompletion {
        try Task.checkCancellation()
        let definition = try registry.definition(for: invocation.call.actionPath)
        return try await Self.perform(invocation, definition: definition)
    }
    /// Shared execution semantics; callers separately enforce permission, queues and resources.
    public static func perform(
        _ invocation: ActionInvocation, definition: ActionDefinition,
        defaultTimeout: Duration = Self.defaultTimeout
    ) async throws -> ActionCompletion {
        try Task.checkCancellation()
        let handler = definition.handler
        let returned: ActionCompletion
        do {
            let budget =
                try definition.estimatingDuration?(invocation.call)
                ?? ActionExecutionBudget(expected: .zero, timeout: definition.timeout ?? defaultTimeout)
            returned = try await ActionDeadline.run(
                budget: budget, report: { await invocation.results.snapshot() },
                body: { try await handler(invocation) })
        } catch {
            try Task.checkCancellation()
            if let report = await invocation.results.snapshot(), definition.kind == .finite {
                return .report(report.recordingFailure(error))
            }
            throw error
        }
        let completion: ActionCompletion
        if case .report(let report) = returned {
            if report.executionFailure != nil { return returned }
            completion = returned
        } else if let report = await invocation.results.snapshot(), definition.kind == .finite {
            completion = .report(report)
        } else {
            try Task.checkCancellation()
            completion = returned
        }
        try Self.validate(completion: completion, kind: definition.kind)
        return completion
    }
    public static func validate(completion: ActionCompletion, kind: ActionDefinition.Kind) throws {
        if case .value(let value) = completion, value.utf8.count > 65_536 {
            throw ActionExecutionError.invalidCompletion
        }
        switch (kind, completion) {
        case (.activityStart, .activityStarted), (.activityStop, .activityStopped),
            (.finite, .completed), (.finite, .value), (.finite, .report), (.state, .completed),
            (.activityUpdate, .completed):
            break
        default: throw ActionExecutionError.invalidCompletion
        }
    }

}
