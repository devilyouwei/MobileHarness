import Foundation
import Synchronization
import Testing

@testable import UI

@Test @MainActor func executionLogHasFourTabsAndPreservesAgentFailuresWithoutSignalRows() {
    #expect(ExecutionLogTab.allCases.map(\.rawValue) == ["Action", "Agent", "Decision", "State"])
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

@Test @MainActor func agentEventRetentionIsBounded() {
    let state = RuntimeLogState()
    for _ in 0..<110 { state.recordAgentEvent(.init(source: "assistant", status: "running", isFailure: false)) }
    #expect(state.agentEvents.count == 100 && state.agentEventEvictions == 10)
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

@Test @MainActor func supersededDecisionIsNeitherModelSuccessNorFailure() {
    let state = RuntimeLogState()
    for (id, route) in [("old", DecisionLogItem.Route.superseded), ("timeout", .failed)] {
        state.record(
            .decision(
                .init(
                    id: id, source: "assistant", inputText: id, duration: .zero, route: route,
                    modelResult: nil, adoptedResult: .enqueue,
                    signalStatus: id == "old" ? "superseded" : "decision_failed",
                    requests: [])))
    }
    #expect(state.visibleDecisions.count == 2)
    state.selectedFilter = .failed
    #expect(state.visibleDecisions.map(\.id) == ["timeout"])
    state.selectedFilter = .succeeded
    #expect(state.visibleDecisions.isEmpty)
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

@Test @MainActor func stateVariablesSortByRecentChangeWithEmptyOnesLast() async {
    let state = RuntimeLogState()
    let box = Mutex<[StateVariableItem]>([])
    state.provideStateVariables { box.withLock { $0 } }
    let early = Date(timeIntervalSince1970: 100)
    box.withLock {
        $0 = [
            .init(path: "agents.assistant.empty", category: .readWrite, value: nil),
            .init(path: "agents.assistant.mood", category: .semantic, value: "calm", writtenAt: early),
            .init(path: "ui.camera", category: .container, value: "{\"on\":false}"),
        ]
    }
    await state.refreshStateVariables(now: Date(timeIntervalSince1970: 200))
    #expect(state.stateVariables.map(\.path) == ["agents.assistant.mood", "ui.camera", "agents.assistant.empty"])
    box.withLock {
        $0[2] = .init(path: "ui.camera", category: .container, value: "{\"on\":true}")
    }
    await state.refreshStateVariables(now: Date(timeIntervalSince1970: 300))
    #expect(state.stateVariables.map(\.path) == ["ui.camera", "agents.assistant.mood", "agents.assistant.empty"])
}
