import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import PlatformKit
import StorageCore
import Testing

@testable import UI

private func activityRecord(
    id: String = UUID().uuidString, channel: String = "Robot",
    phase: ActionExecutionRecord.Phase = .running,
    semantics: ActionExecutionRecord.Semantics = .finite, at time: Date = .now,
    failure: ActionExecutionRecord.Failure? = nil, completion: ActionCompletion? = nil
) -> ActionExecutionRecord {
    ActionExecutionRecord(
        id: id, path: ActionIdentifier(domain: "NexArm", module: "Gesture", function: "dance"),
        source: AgentID.assistant.rawValue,
        sessionID: UUID().uuidString, inputID: UUID().uuidString, channel: channel,
        semantics: semantics, phase: phase,
        admittedAt: time, startedAt: phase == .queued ? nil : time,
        endedAt: [.succeeded, .failed, .cancelled].contains(phase) ? time : nil,
        failure: failure, completion: completion)
}

@Test @MainActor func controlLogMergesWithActionSnapshotsAndUsesItsOwnRetention() throws {
    let log = RuntimeLogState()
    let now = Date.now
    let action = ActionActivityItem(execution: activityRecord(at: now))
    log.record(.actions(revision: 1, records: [action], evictedCount: 5))
    for index in 0...100 {
        let time = now.addingTimeInterval(Double(index + 1))
        log.record(
            .agentControl(
                .init(
                    id: "control-\(index)", title: "state.set", channel: ActionActivityItem.controlChannel,
                    status: "Completed", issueDescriptions: [],
                    execution: .init(
                        phase: index == 100 ? .cancelled : .succeeded,
                        admittedAt: time, startedAt: time, endedAt: time), source: "assistant")))
    }
    #expect(log.evictedCount == 6)
    #expect(log.items.first?.id == action.id && log.items[1].id == "control-1")
    #expect(log.summaries(at: now).map(\.id) == [action.channel])
    log.selectedChannel = ActionActivityItem.controlChannel
    log.record(.actions(revision: 2, records: [], evictedCount: 7))
    #expect(log.selectedChannel == ActionActivityItem.controlChannel)
    #expect(log.visibleActions.count == 100 && log.evictedCount == 8)
    log.selectedFilter = .succeeded
    #expect(log.visibleActions.count == 99)
    log.selectedSource = "writer"
    #expect(log.visibleActions.isEmpty)
}

@Test @MainActor func actionActivityGroupsParallelChannelsAndKeepsDetailsAfterAutoHide() {
    let state = RuntimeLogState()
    let now = Date()
    let robot = activityRecord(at: now)
    let speech = activityRecord(channel: "Speech", at: now)
    let waiting = activityRecord(phase: .queued, at: now)
    state.replace(
        revision: 1, records: [robot, speech, waiting], evictedCount: 0)
    let summaries = state.summaries(at: now)
    #expect(summaries.count == 2)
    #expect(summaries.first { $0.id == "Robot" }?.queued == 1)
    let completed = activityRecord(id: robot.id, phase: .succeeded, at: now, completion: .completed)
    state.replace(revision: 2, records: [completed], evictedCount: 0)
    #expect(state.summaries(at: now.addingTimeInterval(2.9)).count == 1)
    #expect(state.summaries(at: now.addingTimeInterval(3)).isEmpty)
    #expect(state.items.count == 1)
    state.replace(revision: 1, records: [robot], evictedCount: 0)
    #expect(state.items.first?.execution.phase == .succeeded)
}

@Test @MainActor func actionActivityFailuresPersistUntilDismissedOrReplacedAndNeverResurface() {
    let state = RuntimeLogState()
    let now = Date()
    let failure = activityRecord(phase: .failed, at: now, failure: .init(rawValue: "feedbackTimeout"))
    state.replace(revision: 1, records: [failure], evictedCount: 0)
    #expect(state.summaries(at: now.addingTimeInterval(30)).count == 1)
    state.dismiss(failure.id)
    #expect(state.summaries(at: now).isEmpty)
    #expect(state.items.count == 1)
    let success = activityRecord(phase: .succeeded, at: now.addingTimeInterval(1), completion: .completed)
    state.replace(
        revision: 2, records: [failure, success], evictedCount: 0)
    #expect(state.summaries(at: now.addingTimeInterval(2)).first?.item.id == success.id)
    #expect(state.summaries(at: now.addingTimeInterval(10)).isEmpty)
}

@Test @MainActor func actionActivityShowsHonestCancellationAndCompletionSemantics() {
    let cancelling = ActionActivityItem(execution: activityRecord(phase: .cancelling))
    #expect(cancelling.status == "Cancelling")
    #expect(cancelling.isActive)
    let setting = ActionActivityItem(
        execution: activityRecord(phase: .succeeded, semantics: .state, completion: .completed))
    #expect(setting.status == "Set")
    let start = ActionActivityItem(
        execution:
            activityRecord(
                phase: .succeeded, semantics: .activityStart, completion: .activityStarted(UUID().uuidString)
            ))
    #expect(start.status == "Started")
    let cancelled = ActionActivityItem(execution: activityRecord(phase: .cancelled))
    #expect(cancelled.status == "Cancelled")
    var beforeStart = activityRecord(phase: .cancelled)
    beforeStart.startedAt = nil
    #expect(ActionActivityItem(execution: beforeStart).status == "Cancelled before execution")
    let stop = ActionActivityItem(
        execution: activityRecord(
            phase: .succeeded, semantics: .activityStop, completion: .activityStopped(UUID().uuidString)))
    #expect(stop.status == "Ended")
    let failure = ActionActivityItem(
        execution: activityRecord(phase: .failed, failure: .init(rawValue: "feedbackTimeout")))
    #expect(failure.status == "Execution did not complete")
    #expect(failure.title == "NexArm.Gesture.dance")
    #expect(setting.output == "Completed (no return value)")
    #expect(start.output?.hasPrefix("activityStarted:") == true)
}

@Test @MainActor func actionActivityShowsEveryScheduledActionRegardlessOfModuleOrSource() {
    func record(module: String, source: AgentID, channel: String) -> ActionExecutionRecord {
        ActionExecutionRecord(
            id: UUID().uuidString, path: ActionIdentifier(domain: module, module: "Control", function: "fixture"),
            source: source.rawValue,
            sessionID: UUID().uuidString, inputID: UUID().uuidString, channel: channel,
            semantics: .finite)
    }
    let visible = [
        record(module: "NexArm", source: .assistant, channel: "Robot"),
        record(module: "Speech", source: .assistant, channel: "Speech"),
    ]
    let hidden = [
        record(module: "UI", source: .assistant, channel: "Display"),
        record(module: "UI", source: .visionPerception, channel: "Gaze"),
        record(module: "Recognition", source: .speechPerception, channel: "Transcript"),
    ]
    let state = RuntimeLogState()
    state.replace(revision: 1, records: visible + hidden, evictedCount: 0)
    #expect(state.items.map(\.id) == (visible + hidden).map(\.id))
    #expect(state.summaries(at: .now).count == 5)
}

@Test @MainActor func actionActivityUsesThrownDescriptionWithoutAnErrorCatalog() {
    var record = activityRecord(phase: .failed, failure: .init(rawValue: "invalidArguments"))
    record.failureDescription = "跳舞次数必须是 1 到 3 之间的整数"
    #expect(ActionActivityItem(execution: record).status == record.failureDescription)
    record.failure = .operationFailed
    record.failureDescription = "A new handler failure with no presentation mapping"
    #expect(ActionActivityItem(execution: record).status == record.failureDescription)
}

@Test @MainActor func channelSummariesPreserveExactNamesWithoutAssumingSharedTaskOrdering() {
    let state = RuntimeLogState()
    let first = activityRecord(channel: "CustomLane")
    let anotherTask = activityRecord(channel: "CustomLane")
    let differentCase = activityRecord(channel: "customlane")
    state.replace(revision: 1, records: [first, anotherTask, differentCase], evictedCount: 0)
    let summaries = state.summaries(at: .now)
    #expect(Set(summaries.map(\.id)) == ["CustomLane", "customlane"])
    #expect(summaries.first { $0.id == "CustomLane" }?.additionalRunning == 1)
    #expect(summaries.first { $0.id == "CustomLane" }?.item.channel == "CustomLane")
}

extension RuntimeLogState {
    func replace(revision: UInt64, records: [ActionExecutionRecord], evictedCount: UInt64) {
        replace(revision: revision, records: records.map(ActionActivityItem.init), evictedCount: evictedCount)
    }
}

@Test @MainActor func composedActionIssuesRemainVisibleBeyondSummary() throws {
    let report = try ActionReport(entries: [
        .init(
            path: "one", status: .failed, code: .init(rawValue: "targetNotReached"),
            details: ["motor": "3", "target": "1443", "observed": "1418"]),
        .init(path: "two", status: .failed, code: .init(rawValue: "feedbackLost"), details: ["motor": "4"]),
        .init(path: "three", status: .succeeded),
    ])
    let item = ActionActivityItem(
        execution: ActionExecutionRecord(
            id: UUID().uuidString,
            path: ActionIdentifier(domain: "NexArm", module: "Gesture", function: "dance"),
            source: AgentID.assistant.rawValue,
            sessionID: UUID().uuidString, inputID: UUID().uuidString, channel: "Robot",
            semantics: .finite, phase: .failed,
            completion: .report(report)))
    #expect(item.status == "Partially completed · 2 issues")
    #expect(item.issueDescriptions.count == 2)
    #expect(item.issueDescriptions[0].contains("1418"))
    #expect(item.issueDescriptions[1].contains("No position feedback received"))
}

@Test @MainActor func singleHandlerFailurePreservesUnderlyingSpeechDescription() throws {
    let report = try ActionReport(entries: [.init(path: "root", status: .failed, code: .handlerFailed)])
    let item = ActionActivityItem(
        execution: ActionExecutionRecord(
            id: UUID().uuidString, path: ActionIdentifier(domain: "Speech", module: "Playback", function: "speak"),
            source: AgentID.assistant.rawValue,
            sessionID: UUID().uuidString, inputID: UUID().uuidString, channel: "Speech",
            semantics: .finite, phase: .failed,
            completion: .report(report), failureDescription: "语音合成返回了无效音频"))
    #expect(item.issueDescriptions == ["Item 1: 语音合成返回了无效音频"])
}

@Test @MainActor func unknownProviderFailureHasSafePresentationFallback() throws {
    let report = try ActionReport(entries: [
        .init(
            path: "fixture", status: .failed, code: .init(rawValue: "fixture.unknown"),
            details: ["sensor": "depth"])
    ])
    let item = ActionActivityItem(
        execution: activityRecord(phase: .failed, completion: .report(report)))
    #expect(item.issueDescriptions == ["Item 1: Execution failed"])
}

@Test(arguments: [
    "UI.Caption.print", "UI.Caption.beginReplyTurn", "UI.Caption.setTranscript",
    "UI.Caption.finishTranscript", "UI.Expression.setReplyWaiting", "UI.VoiceState.setVoiceState",
    "Speech.Listening.update", "UI.Island.present", "UI.Island.end", "UI.Island.setPresentation",
]) @MainActor func executionLogInternalFilteringMatchesHomeAndPreservesFailures(
    _ function: String
) {
    let parts = function.split(separator: ".").map(String.init)
    func caption(_ phase: ActionExecutionRecord.Phase) -> ActionActivityItem {
        .init(
            execution: .init(
                id: UUID().uuidString, path: .init(domain: parts[0], module: parts[1], function: parts[2]),
                source: AgentID.assistant.rawValue, sessionID: UUID().uuidString,
                inputID: UUID().uuidString, channel: "Display",
                semantics: .finite, phase: phase, admittedAt: .now))
    }
    let state = RuntimeLogState()
    let internalSuccess = caption(.succeeded)
    let internalFailure = caption(.failed)
    let business = ActionActivityItem(execution: activityRecord())
    state.replace(revision: 1, records: [business, internalSuccess, internalFailure], evictedCount: 0)
    #expect(state.visibleActions.map(\.id) == [business.id, internalFailure.id])
    #expect(state.summaries(at: .now).allSatisfy { $0.item.id != internalSuccess.id })
    state.showsInternalActions = true
    #expect(state.visibleActions.count == 3)
    state.selectedFilter = .failed
    #expect(state.visibleActions.map(\.id) == [internalFailure.id])
}

@Test @MainActor func actionActivityLocalizesCopyWithoutTranslatingExecutionEvidence() throws {
    let completed = activityRecord(phase: .succeeded, completion: .completed)
    let translated = ActionActivityItem(execution: completed, language: .simplifiedChinese)
    #expect(translated.status == "已完成")
    #expect(translated.output == "已完成（无返回值）")
    #expect(translated.title == completed.path.description)
    let raw = activityRecord(phase: .succeeded, completion: .value("Completed"))
    #expect(ActionActivityItem(execution: raw, language: .simplifiedChinese).output == "Completed")
    let report = try ActionReport(entries: [
        .init(
            path: "move", status: .failed, code: .init(rawValue: "targetNotReached"),
            details: ["motor": "2", "target": "90", "observed": "85"])
    ])
    let failed = activityRecord(phase: .failed, completion: .report(report))
    let issue = ActionActivityItem(execution: failed, language: .simplifiedChinese)
    #expect(issue.status == "执行失败 · 1 个问题")
    #expect(issue.issueDescriptions == ["第 1 项 · 电机 2: 稳定后未到达目标位置（目标 90，观测 85）"])
    var evidence = activityRecord(phase: .failed)
    evidence.failureDescription = "Producer-owned diagnostic"
    #expect(ActionActivityItem(execution: evidence, language: .simplifiedChinese).status == evidence.failureDescription)
}
