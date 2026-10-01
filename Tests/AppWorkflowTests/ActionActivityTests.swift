import AgentCore
import AppWorkflows
import Foundation
import Testing
import UI

private func activityRecord(
    id: UUID = UUID(), channel: String = "Robot", phase: ActionExecutionRecord.Phase = .running,
    semantics: ActionExecutionRecord.Semantics = .finite, at time: Date = .now,
    failure: ActionExecutionRecord.Failure? = nil, completion: AgentActionCompletion? = nil
) -> ActionExecutionRecord {
    ActionExecutionRecord(
        id: id, path: ActionPath(module: "NexArm", function: "dance"), displayName: "跳舞", source: .assistant,
        sessionID: UUID(), inputID: UUID(), channel: channel, semantics: semantics, phase: phase,
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
    let failure = activityRecord(phase: .failed, at: now, failure: .feedbackTimeout)
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
            activityRecord(phase: .succeeded, semantics: .activityStart, completion: .activityStarted(UUID())))
    #expect(start.status == "已启动")
    let cancelled = ActionActivityItem(execution: activityRecord(phase: .cancelled))
    #expect(cancelled.status == "已取消")
    var beforeStart = activityRecord(phase: .cancelled)
    beforeStart.startedAt = nil
    #expect(ActionActivityItem(execution: beforeStart).status == "执行前已取消")
    let stop = ActionActivityItem(
        execution: activityRecord(phase: .succeeded, semantics: .activityStop, completion: .activityStopped(UUID())))
    #expect(stop.status == "已结束")
    let failure = ActionActivityItem(execution: activityRecord(phase: .failed, failure: .feedbackTimeout))
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
            id: UUID(), path: ActionPath(module: module, function: "fixture"), displayName: "跳舞", source: source,
            sessionID: UUID(), inputID: UUID(), channel: channel, semantics: .finite)
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
    var record = activityRecord(phase: .failed, failure: .invalidArguments)
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
        .init(path: "one", status: .failed, code: .targetNotReached, motor: 3, target: 1443, observed: 1418),
        .init(path: "two", status: .failed, code: .feedbackLost, motor: 4),
        .init(path: "three", status: .succeeded),
    ])
    let item = ActionActivityItem(
        execution: ActionExecutionRecord(
            id: UUID(),
            path: ActionPath(module: "NexArm", function: "dance"), displayName: "跳舞", source: .assistant,
            sessionID: UUID(), inputID: UUID(), channel: "Robot", semantics: .finite, phase: .failed,
            completion: .report(report)))
    #expect(item.status == "部分完成 · 2项问题")
    #expect(item.issueDescriptions.count == 2)
    #expect(item.issueDescriptions[0].contains("1418"))
    #expect(item.issueDescriptions[1].contains("未收到位置反馈"))
}
