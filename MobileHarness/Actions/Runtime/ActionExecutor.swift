import Foundation

public struct ActionExecutor: Sendable {
    private let registry: ActionRegistry
    public init(registry: ActionRegistry) { self.registry = registry }
    @discardableResult
    public func execute(_ invocation: ActionInvocation) async throws -> ActionCompletion {
        try Task.checkCancellation()
        let definition = try registry.definition(for: invocation.call.actionPath)
        let handler = definition.handler
        let returned: ActionCompletion
        do {
            if let estimate = definition.estimatingDuration {
                let budget = try estimate(invocation.call)
                returned = try await ActionDeadline.run(
                    budget: budget, report: { await invocation.results.snapshot() },
                    body: { try await handler(invocation) })
            } else {
                returned = try await handler(invocation)
            }
        } catch {
            if let report = await invocation.results.snapshot(), definition.kind == .finite { return .report(report) }
            throw error
        }
        let completion: ActionCompletion
        if case .report(let report) = returned, report.executionFailure != nil {
            return returned
        } else if let report = await invocation.results.snapshot(), definition.kind == .finite {
            completion = .report(report)
        } else {
            try Task.checkCancellation()
            completion = returned
        }
        switch (definition.kind, completion) {
        case (.activityStart, .activityStarted), (.activityStop, .activityStopped),
            (.finite, .completed), (.finite, .report), (.state, .completed), (.activityUpdate, .completed):
            break
        default: throw ActionExecutionError.invalidCompletion
        }
        return completion
    }
}
