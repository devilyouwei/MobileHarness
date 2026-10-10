import Foundation
import Testing
import UI

@Test @MainActor func executionLogTaskAndRuntimeRetentionIsBounded() {
    let state = ActionActivityState()
    let taskID = UUID()
    let value = TaskLogItem(
        id: taskID, parentID: nil, requester: "assistant", executor: "photographer", title: "拍照", phase: .running)
    for _ in 0..<40 { state.updateTask(value, event: .init(id: UUID(), time: .now, title: "进度", detail: "")) }
    #expect(state.tasks.first?.events.count == 32 && state.tasks.first?.evictedEvents == 8)
    for _ in 0..<110 {
        state.updateTask(
            .init(
                id: UUID(), parentID: nil, requester: "assistant", executor: "memory", title: "历史", phase: .succeeded),
            event: .init(id: UUID(), time: .now, title: "完成", detail: ""))
        state.recordAgentEvent(.init(source: "assistant", status: "running", isFailure: false))
    }
    #expect(state.tasks.count == 100 && state.taskEvictions == 11)
    #expect(state.agentEvents.count == 100 && state.agentEventEvictions == 10)
    state.selectedSource = "photographer"
    #expect(state.visibleTasks.isEmpty)
    state.selectedSource = "memory"
    state.selectedFilter = .succeeded
    #expect(state.visibleTasks.count == 100)
    state.selectedFilter = .failed
    #expect(state.visibleTasks.isEmpty)
}

@Test @MainActor func executionLogHasThreeTabsAndPreservesAgentFailuresWithoutSignalRows() {
    #expect(ExecutionLogTab.allCases.map(\.rawValue) == ["Action", "Task", "Agent"])
    let state = ActionActivityState()
    let id = UUID()
    state.recordIssue(.init(title: "Output", source: "assistant", message: "input rejected: queueFull", inputID: id))
    state.recordIssue(.init(title: "Output", source: "assistant", message: "input rejected: queueFull", inputID: id))
    let other = UUID()
    state.recordIssue(.init(title: "Output", source: "assistant", message: "input rejected: queueFull", inputID: other))
    #expect(state.runtimeIssues.count == 2)
    #expect(Set(state.runtimeIssues.compactMap(\.inputID)) == [id, other])
    #expect(state.sources == ["assistant"])
}

@Test @MainActor func taskActionFilteringUsesRetainedTimelineInputIdentity() {
    let state = ActionActivityState()
    let taskID = UUID()
    let inputID = UUID()
    state.updateTask(
        .init(
            id: taskID, parentID: nil, requester: "assistant", executor: "photographer", title: "拍照", phase: .running),
        event: .init(id: inputID, time: .now, title: "接纳", detail: ""))
    let action = ActionActivityItem(
        id: UUID(), title: "拍摄", channel: "Camera", status: "运行", issueDescriptions: [], symbol: "camera",
        execution: .init(phase: .running, admittedAt: .now, startedAt: .now, endedAt: nil),
        source: "photographer", inputID: inputID)
    state.replace(revision: 1, records: [action], evictedCount: 0)
    state.selectedTaskID = taskID
    #expect(state.visibleActions.map(\.id) == [action.id])
    state.selectedTaskID = UUID()
    #expect(state.visibleActions.isEmpty)
}
