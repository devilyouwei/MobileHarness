import AgentCore
import FunctionContracts
import UI

private struct ActionActivityMapping {
    let execution: ActionExecutionRecord
    var output: String? {
        guard let completion = execution.completion else { return nil }
        if case .completed = completion { return "Completed (no return value)" }
        do {
            let response = try ToolResponse.response(completion, policy: .returning, callID: execution.id)
            return response.map { ActionExecutionRecord.logPreview($0.value, maximumUTF8Bytes: 16_384) }
        } catch {
            return "Could not encode execution result"
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
                                ? "Action timed out; execution ended and step results were retained" : "Action failed")
                    ]
            } ?? []
        return executionIssues
            + report.entries.enumerated().compactMap { index, entry in
                guard entry.status == .failed, entry.code?.rawValue != "cancelled" else { return nil }
                let reason: String
                switch entry.code?.rawValue {
                case "targetNotReached": reason = "Target not reached after settling"
                case "feedbackLost": reason = "No position feedback received"
                case "disconnected": reason = "Robot arm connection unavailable"
                case "sendingFailed": reason = "Could not send command"
                case "admissionFailed": reason = "Channel admission failed"
                case "feedbackFailed": reason = "Could not process position feedback"
                case "timedOut": reason = "Execution timed out"
                case "invalidArguments": reason = "Invalid arguments"
                case "unavailable": reason = "Execution unavailable"
                case "resultCapacityExceeded": reason = "Result count exceeds the declared limit"
                default:
                    if report.entries.count == 1, let detail = execution.failureDescription, !detail.isEmpty {
                        reason = detail
                    } else {
                        reason = "Execution failed"
                    }
                }
                let capturedReason = entry.details["failureDescription"] ?? reason
                let motor = entry.details["motor"].map { " · Motor \($0)" } ?? ""
                let position: String
                if let target = entry.details["target"], let observed = entry.details["observed"] {
                    position = " (target \(target), observed \(observed))"
                } else {
                    position = ""
                }
                return "Item \(index + 1)\(motor): \(capturedReason)\(position)"
            }
    }
    var status: String {
        switch execution.phase {
        case .queued: "Queued"
        case .running: "Running"
        case .cancelling: "Cancelling"
        case .cancelled: execution.startedAt == nil ? "Cancelled before execution" : "Cancelled"
        case .succeeded:
            switch execution.completion {
            case .activityStarted: "Started"
            case .activityStopped: "Ended"
            default:
                execution.semantics == .state || execution.semantics == .activityUpdate ? "Set" : "Completed"
            }
        case .failed:
            if let report, report.hasFailures {
                "\(report.status == .partialFailure ? "Partially completed" : "Execution failed") · \(report.entries.filter { $0.status == .failed }.count + (report.executionFailure == nil ? 0 : 1)) issues"
            } else {
                execution.failureDescription ?? "Execution did not complete"
            }
        }
    }

}

extension ActionActivityItem {
    public init(execution: ActionExecutionRecord) {
        let mapped = ActionActivityMapping(execution: execution)
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
    var displayTitle: String {
        switch self {
        case .delivering: "Delivering"
        case .accepted: "Accepted"
        case .partial: "Partially accepted"
        case .rejected: "Rejected"
        case .suppressed: "Suppressed"
        case .dropped: "Dropped"
        case .unobserved: "No subscriber"
        }
    }
}

extension AgentTaskSignal.Kind {
    var logTitle: String {
        switch self {
        case .request: "Task delegation"
        case .input: "Follow-up input"
        case .progress: "Task progress"
        case .result: "Task result"
        case .cancel: "Cancellation request"
        }
    }
}
extension AgentLifecycle {
    var logTitle: String {
        switch self {
        case .registered: "Registered"
        case .running: "Running"
        case .paused: "Paused"
        case .stopped: "Stopped"
        case .failed: "Runtime failure"
        }
    }
}

extension InputDecisionOutcome {
    func logItem(for snapshot: InputDecisionSnapshot, duration: Duration) -> DecisionLogItem {
        let route: DecisionLogItem.Route =
            switch self.route {
            case .local: .local
            case .cloud: .cloud
            case .fallback: .fallback
            }
        return .init(
            id: snapshot.input.id, source: AgentID.assistant.rawValue, inputText: snapshot.text, duration: duration,
            route: route,
            modelResult: modelResult.map(\.logDisposition), adoptedResult: adopted.logDisposition,
            reason: reason, requests: requests, localFallback: localFallback)
    }
}

extension InputDisposition {
    fileprivate var logDisposition: DecisionLogItem.Disposition {
        switch self {
        case .enqueue: .enqueue
        case .discard: .discard
        case .interrupt: .interrupt
        }
    }
}
