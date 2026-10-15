import Foundation
import Testing
import UI

@Test @MainActor func executionLogTaskAndRuntimeRetentionIsBounded() {
    let state = ActionActivityState()
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
    #expect(state.visibleTasks.count == 1 && state.backgroundTaskCount == 1)
    state.selectedSource = "memory"
    state.selectedFilter = .succeeded
    #expect(state.visibleTasks.count == 99)
    state.selectedFilter = .failed
    #expect(state.visibleTasks.isEmpty)
}

@Test @MainActor func executionLogHasThreeTabsAndPreservesAgentFailuresWithoutSignalRows() {
    #expect(ExecutionLogTab.allCases.map(\.rawValue) == ["Action", "Task", "Agent"])
    let state = ActionActivityState()
    let id = UUID().uuidString
    state.recordIssue(.init(title: "Output", source: "assistant", message: "input rejected: queueFull", inputID: id))
    state.recordIssue(.init(title: "Output", source: "assistant", message: "input rejected: queueFull", inputID: id))
    let other = UUID().uuidString
    state.recordIssue(.init(title: "Output", source: "assistant", message: "input rejected: queueFull", inputID: other))
    #expect(state.runtimeIssues.count == 2)
    #expect(Set(state.runtimeIssues.compactMap(\.inputID)) == [id, other])
    #expect(state.sources == ["assistant"])
}

@Test @MainActor func taskActionFilteringUsesRetainedTimelineInputIdentity() {
    let state = ActionActivityState()
    let taskID = UUID().uuidString
    let inputID = UUID().uuidString
    state.updateTask(
        .init(
            id: taskID, parentID: nil, requester: "assistant", executor: "photographer", title: "拍照", phase: .running),
        event: .init(id: inputID, time: .now, title: "接纳", detail: ""))
    let action = ActionActivityItem(
        id: UUID().uuidString, title: "拍摄", channel: "Camera", status: "运行", issueDescriptions: [],
        symbol: "camera",
        execution: .init(phase: .running, admittedAt: .now, startedAt: .now, endedAt: nil),
        source: "photographer", inputID: inputID)
    state.replace(revision: 1, records: [action], evictedCount: 0)
    state.selectedTaskID = taskID
    #expect(state.visibleActions.map(\.id) == [action.id])
    state.selectedTaskID = UUID().uuidString
    #expect(state.visibleActions.isEmpty)
}

@Test @MainActor func taskLogRetainsFailureAndOriginalTimestamp() {
    let state = ActionActivityState()
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

@Test(arguments: [CGFloat(568), 667, 852, 1024])
func homeTaskStaysAboveCaptionThroughPromotion(viewportHeight: CGFloat) {
    let diameter = min(CGFloat(390) * 0.84, 360)
    let waiting = ConversationCaptionLayout(
        viewportHeight: viewportHeight, faceDiameter: diameter,
        hasTranscript: false, finalized: false, hasTask: true, hasActivity: false)
    for finalized in [false, true] {
        for hasActivity in [false, true] {
            let layout = ConversationCaptionLayout(
                viewportHeight: viewportHeight, faceDiameter: diameter,
                hasTranscript: true, finalized: finalized, hasTask: true, hasActivity: hasActivity)
            #expect(layout.taskCenterY == waiting.taskCenterY)
            #expect(layout.taskCenterY - 9 >= 72)
            #expect(layout.captionCenterY - layout.captionHeight / 2 >= layout.taskCenterY + 9 + 8)
            if finalized {
                #expect(layout.captionCenterY == waiting.captionCenterY)
            } else {
                #expect(layout.captionCenterY == viewportHeight - (hasActivity ? 240 : 120))
            }
        }
    }
    let noTask = ConversationCaptionLayout(
        viewportHeight: viewportHeight, faceDiameter: diameter,
        hasTranscript: true, finalized: false, hasTask: false, hasActivity: false)
    #expect(noTask.captionCenterY == viewportHeight - 120)
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

@Test @MainActor func homeToastShowsNewAgentErrorsWithoutReplayingSnapshotsOrClearingEvidence() {
    let state = ActionActivityState()
    let old = ExecutionIssue(
        title: "Output", source: "assistant", message: "old error", time: Date(timeIntervalSinceNow: -60))
    state.replaceIssues(revision: 1, records: [old], evictedCount: 0)
    #expect(state.errorToast == nil)
    let input = UUID().uuidString
    let fresh = ExecutionIssue(
        title: "Output", source: "assistant", message: "agent.error: httpStatus(400)", inputID: input)
    state.replaceIssues(revision: 2, records: [old, fresh], evictedCount: 0)
    #expect(state.errorToast?.message == fresh.message)
    state.dismissErrorToast(id: UUID().uuidString)
    #expect(state.errorToast?.id == fresh.id)
    state.dismissErrorToast(id: fresh.id)
    state.replaceIssues(revision: 3, records: [old, fresh], evictedCount: 0)
    state.recordIssue(.init(title: "Output", source: "assistant", message: fresh.message, inputID: input))
    #expect(state.errorToast == nil && state.outputIssues.count == 2)
    let other = ExecutionIssue(
        title: "Output", source: "assistant", message: fresh.message, inputID: UUID().uuidString)
    state.recordIssue(other)
    #expect(state.errorToast?.id == other.id)
    state.replaceIssues(revision: 2, records: [], evictedCount: 0)
    #expect(state.outputIssues.count == 2)
}

@Test @MainActor func homeToastKeepsActionFailuresInThePanelWithoutReplacingAgentNotice() {
    let state = ActionActivityState()
    let id = UUID().uuidString
    func item(_ phase: ActionActivityItem.Execution.Phase) -> ActionActivityItem {
        .init(
            id: id, title: "History.Conversation.summarize", channel: "History", status: "failed",
            issueDescriptions: ["httpStatus(400)"], symbol: "exclamationmark.triangle",
            execution: .init(phase: phase, admittedAt: .now, startedAt: .now, endedAt: phase == .failed ? .now : nil),
            source: "memory")
    }
    state.replace(revision: 1, records: [item(.running)], evictedCount: 0)
    #expect(state.errorToast == nil)
    state.replace(revision: 2, records: [item(.failed)], evictedCount: 0)
    #expect(state.errorToast == nil && state.items.first?.isFailure == true)
    let agent = ExecutionIssue(title: "Output", source: "assistant", message: "agent.error: httpStatus(400)")
    state.recordIssue(agent)
    state.replace(revision: 3, records: [item(.failed)], evictedCount: 0)
    #expect(state.errorToast?.id == agent.id)
    state.dismissErrorToast(id: agent.id)
    state.replace(revision: 4, records: [item(.failed)], evictedCount: 0)
    #expect(state.errorToast == nil && state.items.first?.isFailure == true)
}

@Test @MainActor func homeToastShowsUpperLayerFailuresButRetainsCallScopedFailuresOnlyInLogs() {
    let state = ActionActivityState()
    let app = ExecutionIssue(title: "App", source: "runtime", message: "Scene transition failed")
    state.recordIssue(app)
    #expect(state.errorToast?.id == app.id)
    let action = ExecutionIssue(
        title: "NexArm.Tracking.aim", source: "assistant", message: "device disconnected",
        context: .init(workerID: UUID().uuidString, callID: UUID().uuidString))
    state.recordIssue(action)
    #expect(state.errorToast?.id == app.id)
    #expect(state.backgroundIssues.contains(action))
    state.dismissErrorToast(id: app.id)
    state.recordIssue(action)
    #expect(state.errorToast == nil)
    let system = ExecutionIssue(title: "System", source: "system", message: "Service unavailable")
    state.replaceIssues(revision: 1, records: [system, action], evictedCount: 0)
    #expect(state.errorToast?.id == system.id)
    #expect(state.outputIssues.contains(action))
}
