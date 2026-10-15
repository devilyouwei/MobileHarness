import Actions
import ExecutionRuntime
import Foundation
import FunctionContracts
import Storage

/// Bounded staged child composition. Only a successful stage permits the next native effect.
public enum ListeningActivationFeedback {
    public struct Failure: Error, Sendable, ActionReportProviding {
        public let actionReport: ActionReport
    }
    public static func run(
        invocation: any FunctionInput, configuration: SpeechActions.ListeningFeedback,
        feedback: any UIFeedbackCapability,
        prepare: @escaping @Sendable () async throws -> Void,
        capture: @escaping @Sendable () async throws -> Void,
        tail: Duration = .milliseconds(120)
    ) async throws {
        guard tail >= .zero, tail <= .seconds(1) else { throw ActionComposition.ConfigurationError.invalidDelay }
        let definitions = UIModule.feedbackDefinitions(feedback: feedback)
        guard let haptic = definitions.first(where: { $0.path.function == "vibrate" }),
            let cue = definitions.first(where: { $0.path.function == "playCue" })
        else { throw UIActions.FeedbackError.unavailable }
        func child(_ function: ActionFunction, parameters: [String: String]) throws -> FunctionInvocation {
            FunctionInvocation(
                call: FunctionRequest(actionPath: function.path, parameters: parameters),
                context: invocation.context, executionID: UUID().uuidString,
                results: ActionReportStore())
        }
        let hapticInput = try child(
            haptic,
            parameters: [
                "style": configuration.haptic.style.rawValue,
                "intensity": String(configuration.haptic.intensity), "count": String(configuration.haptic.count),
                "intervalMS": String(configuration.haptic.intervalMS),
            ])
        let cueInput = try child(
            cue, parameters: ["cue": configuration.cue.cue.rawValue, "volume": String(configuration.cue.volume)])
        let stages: [(String, ActionComposition)] = [
            (
                "activation",
                try ActionComposition(
                    .parallel([
                        .action("prepare", [], budget: .default) {
                            try await prepare()
                            return .completed
                        },
                        .action(function: cue, invocation: cueInput),
                        .action(function: haptic, invocation: hapticInput),
                    ]))
            ),
            ("tail", try ActionComposition(.delay(tail))),
            (
                "capture",
                try ActionComposition(
                    .action("open", [], budget: .default) {
                        try await capture()
                        return .completed
                    })
            ),
        ]
        var entries: [ActionReport.Entry] = []
        for (name, composition) in stages {
            let stage = try await composition.run()
            entries += stage.entries.map {
                .init(path: name + "." + $0.path, status: $0.status, code: $0.code, details: $0.details)
            }
            var accumulated = try ActionReport(entries: entries)
            if let executionFailure = stage.executionFailure {
                accumulated = accumulated.withExecutionFailure(executionFailure, description: stage.failureDescription)
            }
            if stage.hasFailures || stage.isCancelled || Task.isCancelled {
                if Task.isCancelled, accumulated.executionFailure == nil {
                    accumulated = accumulated.withExecutionFailure(.cancelled)
                }
                try await invocation.results.record(accumulated)
                if Task.isCancelled { throw CancellationError() }
                throw Failure(actionReport: accumulated)
            }
        }
        try await invocation.results.record(ActionReport(entries: entries))
        try Task.checkCancellation()
    }
}

/// One activation-scoped waiter; native admission, failure or cancellation always retires it.
@MainActor
public final class ListeningFeedbackStart {
    private var outcome: Result<Void, any Error>?
    private var waiter: CheckedContinuation<Void, any Error>?
    public init() {}
    public func resolve(_ result: Result<Void, any Error>) {
        guard outcome == nil else { return }
        outcome = result
        let pending = waiter
        waiter = nil
        pending?.resume(with: result)
    }
    public func wait() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            if let outcome {
                try outcome.get()
                return
            }
            guard waiter == nil else { throw UIActions.FeedbackError.unavailable }
            try await withCheckedThrowingContinuation { waiter = $0 }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [self] in resolve(.failure(CancellationError())) }
        }
    }
}
