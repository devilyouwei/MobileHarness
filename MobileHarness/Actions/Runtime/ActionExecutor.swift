import Foundation

public struct ActionExecutor: Sendable {
    public static let defaultTimeout: Duration = .seconds(30)
    private let registry: ActionRegistry
    public init(registry: ActionRegistry) { self.registry = registry }
    @discardableResult
    public func execute(_ invocation: ActionInvocation) async throws -> ActionCompletion {
        try Task.checkCancellation()
        let definition = try registry.definition(for: invocation.call.actionPath)
        let handler = definition.handler
        let returned: ActionCompletion
        do {
            let budget =
                try definition.estimatingDuration?(invocation.call)
                ?? ActionExecutionBudget(expected: .zero, timeout: Self.defaultTimeout)
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
