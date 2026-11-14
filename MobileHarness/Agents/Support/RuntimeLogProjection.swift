import AgentCore
import FunctionContracts
import UI

private struct ActionActivityMapping {
    let execution: ActionExecutionRecord
    let language: AppLanguage
    var output: String? {
        guard let completion = execution.completion else { return nil }
        if case .completed = completion { return language.text("Completed (no return value)") }
        do {
            let response = try ToolResponse.response(completion, policy: .returning, callID: execution.id)
            return response.map { ActionExecutionRecord.logPreview($0.value, maximumUTF8Bytes: 16_384) }
        } catch {
            return language.text("Could not encode execution result")
        }
    }
    var report: ActionReport? {
        if case .report(let report) = execution.completion { return report }
        return nil
    }
    var issueDescriptions: [String] {
        guard let report else { return [] }
        let executionIssues: [String] =
            report.executionFailure.flatMap {
                guard $0 != .cancelled else { return nil }
                return
                    [
                        report.failureDescription ?? execution.failureDescription
                            ?? ($0 == .timedOut
                                ? language.text("Action timed out; execution ended and step results were retained")
                                : language.text("Action failed"))
                    ]
            } ?? []
        return executionIssues
            + report.entries.enumerated().compactMap { index, entry in
                guard entry.status == .failed, entry.code?.rawValue != "cancelled" else { return nil }
                let reason: String
                switch entry.code?.rawValue {
                case "targetNotReached": reason = language.text("Target not reached after settling")
                case "feedbackLost": reason = language.text("No position feedback received")
                case "disconnected": reason = language.text("Robot arm connection unavailable")
                case "sendingFailed": reason = language.text("Could not send command")
                case "admissionFailed": reason = language.text("Channel admission failed")
                case "feedbackFailed": reason = language.text("Could not process position feedback")
                case "timedOut": reason = language.text("Execution timed out")
                case "invalidArguments": reason = language.text("Invalid arguments")
                case "unavailable": reason = language.text("Execution unavailable")
                case "resultCapacityExceeded": reason = language.text("Result count exceeds the declared limit")
                default:
                    if report.entries.count == 1, let detail = execution.failureDescription, !detail.isEmpty {
                        reason = detail
                    } else {
                        reason = language.text("Execution failed")
                    }
                }
                let capturedReason = entry.details["failureDescription"] ?? reason
                let motor = entry.details["motor"].map { language.format(" · Motor %@", $0) } ?? ""
                let position: String
                if let target = entry.details["target"], let observed = entry.details["observed"] {
                    position = language.format(" (target %@, observed %@)", target, observed)
                } else {
                    position = ""
                }
                return language.format("Item %lld%@: %@%@", index + 1, motor, capturedReason, position)
            }
    }
    var status: String {
        switch execution.phase {
        case .queued: language.text("Queued")
        case .running: language.text("Running")
        case .cancelling: language.text("Cancelling")
        case .cancelled:
            execution.startedAt == nil ? language.text("Cancelled before execution") : language.text("Cancelled")
        case .succeeded:
            switch execution.completion {
            case .activityStarted: language.text("Started")
            case .activityStopped: language.text("Ended")
            default:
                execution.semantics == .state || execution.semantics == .activityUpdate
                    ? language.text("Set") : language.text("Completed")
            }
        case .failed:
            if let report, report.hasFailures {
                language.format(
                    "%@ · %lld issues",
                    report.status == .partialFailure
                        ? language.text("Partially completed") : language.text("Execution failed"),
                    report.entries.filter { $0.status == .failed }.count + (report.executionFailure == nil ? 0 : 1))
            } else {
                execution.failureDescription ?? language.text("Execution did not complete")
            }
        }
    }

}

extension ActionActivityItem {
    public init(execution: ActionExecutionRecord) {
        self.init(execution: execution, language: .english)
    }

    public init(execution: ActionExecutionRecord, language: AppLanguage) {
        let mapped = ActionActivityMapping(execution: execution, language: language)
        self.init(
            id: execution.id, title: execution.path.description, channel: execution.channel, status: mapped.status,
            issueDescriptions: mapped.issueDescriptions,
            execution: .init(
                phase: execution.phase.presentationPhase, admittedAt: execution.admittedAt,
                startedAt: execution.startedAt, endedAt: execution.endedAt),
            source: execution.source, inputID: execution.inputID,
            isInternal: [
                "UI.Caption.print", "UI.Caption.beginReplyTurn", "UI.Caption.setTranscript",
                "UI.Caption.finishTranscript", "UI.Expression.setReplyWaiting", "UI.VoiceState.setVoiceState",
                "Speech.Listening.update", "UI.Island.present", "UI.Island.update", "UI.Island.end",
                "UI.Island.setPresentation",
            ].contains(execution.path.description),
            parameters: execution.parameters, output: mapped.output)
    }
}

extension ActionExecutionRecord.Phase {
    var presentationPhase: ActionActivityItem.Execution.Phase {
        switch self {
        case .queued: .queued
        case .running: .running
        case .cancelling: .cancelling
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}

extension SignalTraceRecord.Phase {
    func displayTitle(language: AppLanguage) -> String {
        switch self {
        case .delivering: language.text("Delivering")
        case .accepted: language.text("Accepted")
        case .partial: language.text("Partially accepted")
        case .rejected: language.text("Rejected")
        case .suppressed: language.text("Suppressed")
        case .dropped: language.text("Dropped")
        case .unobserved: language.text("No subscriber")
        }
    }
}

extension AgentTaskSignal.Kind {
    func logTitle(language: AppLanguage) -> String {
        switch self {
        case .request: language.text("Task delegation")
        case .input: language.text("Follow-up input")
        case .progress: language.text("Task progress")
        case .result: language.text("Task result")
        case .cancel: language.text("Cancellation request")
        }
    }
}
extension AgentLifecycle {
    func logTitle(language: AppLanguage) -> String {
        switch self {
        case .registered: language.text("Registered")
        case .running: language.text("Running")
        case .paused: language.text("Paused")
        case .stopped: language.text("Stopped")
        case .failed: language.text("Runtime failure")
        }
    }
}
