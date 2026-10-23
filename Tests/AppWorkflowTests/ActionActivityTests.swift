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
    failure: ActionExecutionRecord.Failure? = nil, completion: AgentActionCompletion? = nil
) -> ActionExecutionRecord {
    ActionExecutionRecord(
        id: id, path: ActionPath(domain: "NexArm", module: "Gesture", function: "dance"), displayName: "跳舞",
        source: .assistant,
        sessionID: UUID().uuidString, inputID: UUID().uuidString, channel: channel,
        semantics: semantics, phase: phase,
        admittedAt: time, startedAt: phase == .queued ? nil : time,
        endedAt: [.succeeded, .failed, .cancelled].contains(phase) ? time : nil,
        failure: failure, completion: completion)
}

@Test @MainActor func actionActivityGroupsParallelChannelsAndKeepsDetailsAfterAutoHide() {
    let state = ActionActivityState()
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
    let state = ActionActivityState()
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
    #expect(cancelling.status == "正在取消")
    #expect(cancelling.isActive)
    let setting = ActionActivityItem(execution: activityRecord(phase: .succeeded, semantics: .state))
    #expect(setting.status == "已设置")
    let start = ActionActivityItem(
        execution:
            activityRecord(
                phase: .succeeded, semantics: .activityStart, completion: .activityStarted(UUID().uuidString)
            ))
    #expect(start.status == "已启动")
    let cancelled = ActionActivityItem(execution: activityRecord(phase: .cancelled))
    #expect(cancelled.status == "已取消")
    var beforeStart = activityRecord(phase: .cancelled)
    beforeStart.startedAt = nil
    #expect(ActionActivityItem(execution: beforeStart).status == "执行前已取消")
    let stop = ActionActivityItem(
        execution: activityRecord(
            phase: .succeeded, semantics: .activityStop, completion: .activityStopped(UUID().uuidString)))
    #expect(stop.status == "已结束")
    let failure = ActionActivityItem(
        execution: activityRecord(phase: .failed, failure: .init(rawValue: "feedbackTimeout")))
    #expect(failure.status == "执行未完成")
    #expect(failure.title == "跳舞")
}

@Test @MainActor func actionActivityWorkflowConsumesInitialAndLatestSnapshotsWithoutPageLifetime() async throws {
    let state = ActionActivityState()
    let workflow = ActionActivityWorkflow(state: state)
    let pair = AsyncStream<ActionExecutionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    workflow.start { pair.stream }
    let record = activityRecord(phase: .succeeded)
    pair.continuation.yield(ActionExecutionSnapshot(revision: 5, records: [record], evictedCount: 3))
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while state.revision != 5, ContinuousClock.now < deadline { await Task.yield() }
    #expect(state.revision == 5)
    #expect(state.items.first?.id == record.id)
    #expect(state.evictedCount == 3)
    pair.continuation.finish()
}

@Test @MainActor func actionActivityShowsEveryScheduledActionRegardlessOfModuleOrSource() async {
    func record(module: String, source: AgentID, channel: String) -> ActionExecutionRecord {
        ActionExecutionRecord(
            id: UUID().uuidString, path: ActionPath(domain: module, module: "Control", function: "fixture"),
            displayName: "跳舞",
            source: source,
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
    let state = ActionActivityState()
    let workflow = ActionActivityWorkflow(state: state)
    let pair = AsyncStream<ActionExecutionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    workflow.start { pair.stream }
    pair.continuation.yield(ActionExecutionSnapshot(revision: 1, records: visible + hidden))
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while state.revision != 1, ContinuousClock.now < deadline { await Task.yield() }
    #expect(state.items.map(\.id) == (visible + hidden).map(\.id))
    #expect(state.summaries(at: .now).count == 5)
    pair.continuation.finish()
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
    let state = ActionActivityState()
    let first = activityRecord(channel: "CustomLane")
    let anotherTask = activityRecord(channel: "CustomLane")
    let differentCase = activityRecord(channel: "customlane")
    state.replace(revision: 1, records: [first, anotherTask, differentCase], evictedCount: 0)
    let summaries = state.summaries(at: .now)
    #expect(Set(summaries.map(\.id)) == ["CustomLane", "customlane"])
    #expect(summaries.first { $0.id == "CustomLane" }?.additionalRunning == 1)
    #expect(summaries.first { $0.id == "CustomLane" }?.item.channelTitle == "CustomLane")
}

extension ActionActivityState {
    func replace(revision: UInt64, records: [ActionExecutionRecord], evictedCount: UInt64) {
        replace(revision: revision, records: records.map(ActionActivityItem.init), evictedCount: evictedCount)
    }
}

@Test @MainActor func composedActionIssuesRemainVisibleBeyondSummary() throws {
    let report = try AgentActionReport(entries: [
        .init(
            path: "one", status: .failed, code: .init(rawValue: "targetNotReached"),
            details: ["motor": "3", "target": "1443", "observed": "1418"]),
        .init(path: "two", status: .failed, code: .init(rawValue: "feedbackLost"), details: ["motor": "4"]),
        .init(path: "three", status: .succeeded),
    ])
    let item = ActionActivityItem(
        execution: ActionExecutionRecord(
            id: UUID().uuidString,
            path: ActionPath(domain: "NexArm", module: "Gesture", function: "dance"), displayName: "跳舞",
            source: .assistant,
            sessionID: UUID().uuidString, inputID: UUID().uuidString, channel: "Robot",
            semantics: .finite, phase: .failed,
            completion: .report(report)))
    #expect(item.status == "部分完成 · 2项问题")
    #expect(item.issueDescriptions.count == 2)
    #expect(item.issueDescriptions[0].contains("1418"))
    #expect(item.issueDescriptions[1].contains("未收到位置反馈"))
}

@Test @MainActor func singleHandlerFailurePreservesUnderlyingSpeechDescription() throws {
    let report = try AgentActionReport(entries: [.init(path: "root", status: .failed, code: .handlerFailed)])
    let item = ActionActivityItem(
        execution: ActionExecutionRecord(
            id: UUID().uuidString, path: ActionPath(domain: "Speech", module: "Playback", function: "speak"),
            displayName: "朗读回复",
            source: .assistant,
            sessionID: UUID().uuidString, inputID: UUID().uuidString, channel: "Speech",
            semantics: .finite, phase: .failed,
            completion: .report(report), failureDescription: "语音合成返回了无效音频"))
    #expect(item.issueDescriptions == ["第1项：语音合成返回了无效音频"])
}

@Test @MainActor func unknownProviderFailureHasSafePresentationFallback() throws {
    let report = try AgentActionReport(entries: [
        .init(
            path: "fixture", status: .failed, code: .init(rawValue: "fixture.unknown"),
            details: ["sensor": "depth"])
    ])
    let item = ActionActivityItem(
        execution: activityRecord(phase: .failed, completion: .report(report)))
    #expect(item.issueDescriptions == ["第1项：执行失败"])
}

@Test @MainActor func executionLogInternalFilteringMatchesHomeAndPreservesFailures() {
    func caption(_ phase: ActionExecutionRecord.Phase) -> ActionActivityItem {
        .init(
            execution: .init(
                id: UUID().uuidString, path: .init(domain: "UI", module: "Caption", function: "print"),
                displayName: "字幕", source: .assistant, sessionID: UUID().uuidString,
                inputID: UUID().uuidString, channel: "Display",
                semantics: .finite, phase: phase, admittedAt: .now))
    }
    let state = ActionActivityState()
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

@Test @MainActor func executionLogTaskReceiptIsNotCompletionAndLateProgressCannotReopen() async throws {
    let state = ActionActivityState()
    let workflow = ActionActivityWorkflow(state: state)
    let pair = AsyncStream<SignalTraceSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    workflow.startTasks(
        observe: { pair.stream }, taskContent: { signal in ("task report", signal.kind == .progress) })
    let scope = AgentTaskScope(
        id: UUID().uuidString, requester: .assistant, executor: .photographer,
        sessionID: UUID().uuidString)
    func record(
        _ kind: AgentTaskSignal.Kind, status: AgentTaskSignal.Status? = nil, businessContract: String = "fixture"
    ) throws -> SignalTraceRecord {
        let signal = try AgentTaskSignal(
            kind: kind, scope: scope, businessContract: businessContract, data: Data(), status: status)
        let input = AgentInput(
            id: UUID().uuidString,
            sessionID: scope.sessionID, payload: .observation(try signal.message()), taskScope: scope)
        var value = SignalTraceRecord(input: input, mode: .send, targets: [.photographer], summary: "")
        value.phase = .accepted
        return value
    }
    let accepted = try record(.request)
    pair.continuation.yield(.init(revision: 1, records: [accepted]))
    let end = ContinuousClock.now.advanced(by: .seconds(3))
    while state.tasks.isEmpty && ContinuousClock.now < end { await Task.yield() }
    #expect(state.tasks.first?.phase == .accepted)
    #expect(state.tasks.first?.isTerminal == false)
    let question = try record(.progress)
    pair.continuation.yield(.init(revision: 2, records: [accepted, question]))
    while state.tasks.first?.phase != .waitingUser && ContinuousClock.now < end { await Task.yield() }
    #expect(state.tasks.first?.phase == .waitingUser)
    let playback = try record(.progress, businessContract: "runtime.replyFinished")
    pair.continuation.yield(.init(revision: 3, records: [accepted, question, playback]))
    #expect(state.tasks.first?.phase == .waitingUser)
    let result = try record(.result, status: .succeeded)
    pair.continuation.yield(.init(revision: 4, records: [accepted, question, playback, result]))
    while state.tasks.first?.phase != .succeeded && ContinuousClock.now < end { await Task.yield() }
    #expect(state.tasks.first?.phase == .succeeded)
    let progress = try record(.progress)
    pair.continuation.yield(.init(revision: 5, records: [accepted, question, playback, result, progress]))
    while state.tasks.first?.events.count != 4 && ContinuousClock.now < end { await Task.yield() }
    #expect(state.tasks.first?.phase == .succeeded)
    #expect(state.tasks.first?.events.count == 4)
    pair.continuation.finish()
}
