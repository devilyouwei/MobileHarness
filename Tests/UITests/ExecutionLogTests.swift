import Foundation
import Testing

@testable import UI

@Test @MainActor func executionLogTaskAndRuntimeRetentionIsBounded() {
    let state = RuntimeLogState()
    let taskID = UUID().uuidString
    var value = TaskLogItem(
        id: taskID, parentID: nil, requester: "assistant", executor: "photographer", title: "拍照", phase: .running)
    value.execution = "background"
    for _ in 0..<40 {
        state.updateTask(value, event: .init(id: UUID().uuidString, time: .now, title: "进度", detail: ""))
    }
    #expect(state.tasks.first?.events.count == 32 && state.tasks.first?.evictedEvents == 8)
    for _ in 0..<110 {
        state.updateTask(
            .init(
                id: UUID().uuidString, parentID: nil, requester: "assistant", executor: "memory",
                title: "历史", phase: .succeeded),
            event: .init(id: UUID().uuidString, time: .now, title: "完成", detail: ""))
        state.recordAgentEvent(.init(source: "assistant", status: "running", isFailure: false))
    }
    #expect(state.tasks.count == 100 && state.taskEvictions == 11)
    #expect(state.agentEvents.count == 100 && state.agentEventEvictions == 10)
    state.selectedSource = "photographer"
    #expect(state.visibleTasks.map(\.id) == [taskID])
    state.selectedSource = "memory"
    state.selectedFilter = .succeeded
    #expect(state.visibleTasks.count == 99)
    state.selectedFilter = .failed
    #expect(state.visibleTasks.isEmpty)
}

@Test @MainActor func executionLogHasFourTabsAndPreservesAgentFailuresWithoutSignalRows() {
    #expect(ExecutionLogTab.allCases.map(\.rawValue) == ["Action", "Task", "Agent", "Decision"])
    let state = RuntimeLogState()
    let id = UUID().uuidString
    state.record(.issue(.init(title: "Output", source: "assistant", message: "input rejected: queueFull", inputID: id)))
    state.record(.issue(.init(title: "Output", source: "assistant", message: "input rejected: queueFull", inputID: id)))
    let other = UUID().uuidString
    state.record(
        .issue(.init(title: "Output", source: "assistant", message: "input rejected: queueFull", inputID: other)))
    #expect(state.runtimeIssues.count == 2)
    #expect(Set(state.runtimeIssues.compactMap(\.inputID)) == [id, other])
    #expect(state.sources == ["assistant"])
}

@Test @MainActor func taskActionFilteringUsesRetainedTimelineInputIdentity() {
    let state = RuntimeLogState()
    let taskID = UUID().uuidString
    let inputID = UUID().uuidString
    state.updateTask(
        .init(
            id: taskID, parentID: nil, requester: "assistant", executor: "photographer", title: "拍照", phase: .running),
        event: .init(id: inputID, time: .now, title: "接纳", detail: ""))
    let action = ActionActivityItem(
        id: UUID().uuidString, title: "拍摄", channel: "Camera", status: "运行", issueDescriptions: [],
        execution: .init(phase: .running, admittedAt: .now, startedAt: .now, endedAt: nil),
        source: "photographer", inputID: inputID)
    state.replace(revision: 1, records: [action], evictedCount: 0)
    state.selectedTaskID = taskID
    #expect(state.visibleActions.map(\.id) == [action.id])
    state.selectedTaskID = UUID().uuidString
    #expect(state.visibleActions.isEmpty)
}

@Test @MainActor func taskLogRetainsFailureAndOriginalTimestamp() {
    let state = RuntimeLogState()
    let original = Date(timeIntervalSince1970: 100)
    var task = TaskLogItem(
        id: UUID().uuidString, parentID: nil, requester: "", executor: "assistant", title: "拍照",
        phase: .failed)
    state.updateTask(task, event: .init(id: UUID().uuidString, time: original, title: "running", detail: ""))
    task.failure = "Capture denied by device"
    state.updateTask(task, event: .init(id: UUID().uuidString, time: original, title: "failed", detail: ""))
    #expect(state.tasks.first?.failure == task.failure)
    #expect(state.tasks.first?.events.first?.time == original)
}

@Test @MainActor func homeCameraStartsOffWithoutPreviewOrPose() {
    let camera = CameraState()
    #expect(!camera.isEnabled && !camera.isVisible && !camera.isBusy)
    #expect(camera.skeleton == nil && camera.message == nil && !camera.needsSettings)
}

@Test(arguments: [CGFloat(320), 568, 667, 852, 1024])
func homeCaptionsKeepFixedDisjointRoleRegions(viewportHeight: CGFloat) {
    let diameter = min(CGFloat(390) * 0.84, 360)
    let layout = ConversationCaptionLayout(viewportHeight: viewportHeight, faceDiameter: diameter)
    let userTop = layout.captionCenterY - layout.captionHeight / 2
    let userBottom = layout.captionCenterY + layout.captionHeight / 2
    let replyTop = layout.replyCenterY - layout.replyHeight / 2
    #expect(userTop >= 72)
    #expect(replyTop >= userBottom + 24)
    #expect(layout.replyCenterY + layout.replyHeight / 2 <= viewportHeight)
    // Neither finalization nor channel activity is a layout input.
    #expect(layout.captionCenterY < layout.replyCenterY)
}

@Test @MainActor func homeEyesFollowEnabledSessionAcrossRecognitionAndReplyPauses() {
    let state = ConversationState()
    #expect(state.displayedExpression == .closed)
    state.expression = .happy
    #expect(state.displayedExpression == .closed)
    state.isVoiceActive = true
    state.expression = nil
    for phase in [VoicePhase.loading, .listening, .processing, .speaking] {
        state.voicePhase = phase
        #expect(state.displayedExpression == .clear)
    }
    state.expression = .closed
    #expect(state.displayedExpression == .closed)
    state.expression = .happy
    #expect(state.displayedExpression == .happy)
    state.isVoiceActive = false
    state.voicePhase = .failed
    #expect(state.displayedExpression == .closed)
    state.voicePhase = .idle
    #expect(state.displayedExpression == .closed)
    #expect(EyeExpression(rawValue: "closed") == .closed)
}

@Test @MainActor func homeToastShowsNewAgentErrorsWithoutReplayingOrClearingEvidence() {
    let log = RuntimeLogState()
    let notices = HomeNoticeState()
    let old = ExecutionIssue(
        title: "Output", source: "assistant", message: "old error", time: Date(timeIntervalSinceNow: -60))
    log.record(.issue(old))
    notices.offerToast(old)
    #expect(notices.errorToast == nil)
    let fresh = ExecutionIssue(
        title: "Output", source: "assistant", message: "agent.error: httpStatus(400)", inputID: "fresh")
    log.record(.issue(fresh))
    notices.offerToast(fresh)
    #expect(notices.errorToast?.message == fresh.message)
    notices.dismissErrorToast(id: "different")
    #expect(notices.errorToast?.id == fresh.id)
    notices.dismissErrorToast(id: fresh.id)
    notices.offerToast(fresh)
    #expect(notices.errorToast == nil && log.issues.count == 2)
}

@Test @MainActor func homeToastKeepsActionFailuresInThePanelWithoutReplacingAgentNotice() {
    let state = RuntimeLogState()
    let notices = HomeNoticeState()
    let id = UUID().uuidString
    func item(_ phase: ActionActivityItem.Execution.Phase) -> ActionActivityItem {
        .init(
            id: id, title: "History.Conversation.summarize", channel: "History", status: "failed",
            issueDescriptions: ["httpStatus(400)"],
            execution: .init(phase: phase, admittedAt: .now, startedAt: .now, endedAt: phase == .failed ? .now : nil),
            source: "memory")
    }
    state.replace(revision: 1, records: [item(.running)], evictedCount: 0)
    #expect(notices.errorToast == nil)
    state.replace(revision: 2, records: [item(.failed)], evictedCount: 0)
    #expect(notices.errorToast == nil && state.items.first?.isFailure == true)
    let agent = ExecutionIssue(title: "Output", source: "assistant", message: "agent.error: httpStatus(400)")
    state.record(.issue(agent))
    notices.offerToast(agent)
    state.replace(revision: 3, records: [item(.failed)], evictedCount: 0)
    #expect(notices.errorToast?.id == agent.id)
    notices.dismissErrorToast(id: agent.id)
    state.replace(revision: 4, records: [item(.failed)], evictedCount: 0)
    #expect(notices.errorToast == nil && state.items.first?.isFailure == true)
}

@Test @MainActor func homeToastShowsUpperLayerFailuresButRetainsCallScopedFailuresOnlyInLogs() {
    let state = RuntimeLogState()
    let notices = HomeNoticeState()
    let app = ExecutionIssue(title: "App", source: "runtime", message: "Scene transition failed")
    state.record(.issue(app))
    notices.offerToast(app)
    #expect(notices.errorToast?.id == app.id)
    let action = ExecutionIssue(
        title: "NexArm.Tracking.aim", source: "assistant", message: "device disconnected",
        context: .init(workerID: UUID().uuidString, callID: UUID().uuidString))
    state.record(.issue(action))
    notices.offerToast(action)
    #expect(notices.errorToast?.id == app.id)
    #expect(state.issues.contains(action))
    notices.dismissErrorToast(id: app.id)
    state.record(.issue(action))
    notices.offerToast(action)
    #expect(notices.errorToast == nil)
    let system = ExecutionIssue(title: "System", source: "system", message: "Service unavailable")
    state.record(.issue(system))
    notices.offerToast(system)
    #expect(notices.errorToast?.id == system.id)
    #expect(state.issues.contains(action))
}

@Test @MainActor func classifiedAgentIssueBoundsDetailsWithoutLeakingThemIntoToast() {
    let state = RuntimeLogState()
    let issue = ExecutionIssue(
        title: "modelResponse", source: "assistant", message: String(repeating: "x", count: 3000),
        failureCode: "agent.model.tool.invalidArguments", userMessage: "工具参数格式错误", category: "模型响应异常")
    state.record(.issue(issue))
    #expect(issue.message.count == 2048)
    let notices = HomeNoticeState()
    notices.offerToast(issue)
    #expect(notices.visibleNotice?.text == "工具参数格式错误")
    #expect(state.runtimeIssues.first?.failureCode == "agent.model.tool.invalidArguments")
}

@Test @MainActor func runtimeLogDecisionRetentionSortingAndFiltering() {
    let state = RuntimeLogState()
    for index in 0..<101 {
        let failed = index == 100
        state.record(
            .decision(
                .init(
                    id: String(index), source: failed ? "assistant" : "fixture", inputText: "输入 \(index)",
                    time: Date(timeIntervalSince1970: Double(index)), duration: .milliseconds(index),
                    route: failed ? .fallback : .local,
                    modelResult: failed ? nil : .interrupt, adoptedResult: .enqueue, reason: "fixture",
                    requests: failed ? [] : ["system\nfixture"])))
    }
    state.record(
        .decision(
            .init(
                id: "100", source: "assistant", inputText: "重复记录", duration: .seconds(1), route: .cloud,
                modelResult: .discard,
                adoptedResult: .discard, requests: [])))
    #expect(state.decisions.count == 100 && state.decisionEvictions == 1)
    #expect(state.visibleDecisions.first?.id == "100" && state.visibleDecisions.last?.id == "1")
    #expect(state.visibleDecisions.first?.modelResult == nil)
    #expect(state.visibleDecisions.first?.inputText == "输入 100")
    #expect(state.visibleDecisions.first?.duration == .milliseconds(100))
    state.selectedFilter = .failed
    #expect(state.visibleDecisions.map(\.id) == ["100"])
    state.selectedSource = "fixture"
    #expect(state.visibleDecisions.isEmpty)
    state.selectedFilter = .succeeded
    #expect(state.visibleDecisions.count == 99)
    #expect(state.visibleDecisions.first?.modelResult == .interrupt)
    #expect(state.visibleDecisions.first?.adoptedResult == .enqueue)
    #expect(state.visibleDecisions.first?.requests == ["system\nfixture"])
}

@Test @MainActor func actionLogFiltersExactChannelAlongsideStatusAndSource() {
    let state = RuntimeLogState()
    func item(_ id: String, channel: String, source: String, phase: ActionActivityItem.Execution.Phase)
        -> ActionActivityItem
    {
        .init(
            id: id, title: "Fixture.Action.perform", channel: channel, status: "status", issueDescriptions: [],
            execution: .init(phase: phase, admittedAt: .now, startedAt: nil, endedAt: nil),
            source: source)
    }
    let robot = item("robot", channel: "Robot", source: "assistant", phase: .succeeded)
    let camera = item("camera", channel: "Camera", source: "assistant", phase: .succeeded)
    let failed = item("failed", channel: "Robot", source: "assistant", phase: .failed)
    let custom = item("custom", channel: "robot", source: "other", phase: .succeeded)
    state.replace(revision: 1, records: [robot, camera, failed, custom], evictedCount: 0)
    #expect(state.actionChannels == ["Camera", "Robot", "robot"])
    state.selectedChannel = "Robot"
    #expect(state.visibleActions.map(\.id) == ["robot", "failed"])
    state.selectedFilter = .succeeded
    #expect(state.visibleActions.map(\.id) == ["robot"])
    state.selectedSource = "other"
    #expect(state.visibleActions.isEmpty)
    state.replace(revision: 2, records: [camera, custom], evictedCount: 2)
    #expect(state.selectedChannel == nil)
    #expect(state.visibleActions.map(\.id) == ["custom"])
}
