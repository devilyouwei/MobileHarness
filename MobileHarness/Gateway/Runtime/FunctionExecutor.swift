import Foundation
import FunctionContracts

public struct FunctionExecutor: Sendable {
    public static let defaultTimeout: Duration = .seconds(30)
    private let registry: FunctionRegistry
    public init(registry: FunctionRegistry) { self.registry = registry }
    @discardableResult
    public func execute(_ input: any FunctionInput) async throws -> ActionCompletion {
        try await Self.perform(input, definition: registry.definition(for: input.call.actionPath))
    }
    /// Normalize a producer exception without discarding its already completed child outcomes.
    public static func failureReport(for error: any Error) -> ActionReport {
        ((error as? any ActionReportProviding)?.actionReport ?? .failure(ActionReport.code(for: error)))
            .recordingFailure(error)
    }

    /// Shared execution semantics; callers separately enforce permission, queues and resources.
    public static func perform(
        _ invocation: any FunctionInput, definition: ActionFunction,
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
    public static func validate(completion: ActionCompletion, kind: ActionFunction.Kind) throws {
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
