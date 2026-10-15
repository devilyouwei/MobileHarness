import Actions
import AppWorkflows
import ExecutionRuntime
import Foundation
import FunctionContracts
import Storage
import Testing
import UI

private func homeEffectInput(session: String = UUID().uuidString) -> FunctionInvocation {
    .init(
        call: .init(actionPath: .init(domain: "UI", module: "Light", function: "updateLight")),
        context: .init(source: "assistant", sessionID: session, inputID: UUID().uuidString),
        executionID: UUID().uuidString, results: ActionReportStore())
}

@Test @MainActor func homeEffectsKeepConsentAndErrorEvidenceIndependent() async throws {
    let activity = ActionActivityState()
    let state = ConversationState()
    state.expressionRendererAvailable = true
    let effects = HomeEffectsWorkflow(activity: activity)
    effects.bind(state)
    let input = homeEffectInput()
    try await effects.updateLight(
        .init(origin: .init(x: 0.1, y: 0.8), initialOpacity: 0.85, intensity: 1), invocation: input)
    #expect(state.decorativeLight?.origin == .init(x: 0.1, y: 0.8))
    #expect(!state.isVoiceActive && state.displayedExpression == .closed && state.listeningAnimationID == nil)
    try await effects.showNotice(.init(text: "提醒", tone: .info), invocation: input)
    #expect(activity.visibleNotice?.text == "提醒" && activity.backgroundIssues.isEmpty)
    activity.recordIssue(.init(title: "失败", source: "assistant", message: "真实异常"))
    #expect(activity.visibleNotice?.text == "真实异常")
    await #expect(throws: HomeEffectsWorkflow.Error.self) {
        try await effects.showNotice(.init(text: "不能覆盖异常", tone: .warning), invocation: input)
    }
    try await effects.dismissNotice(invocation: input)
    #expect(activity.errorToast != nil && activity.notice == nil)
    effects.stop()
    #expect(state.decorativeLight == nil && activity.errorToast != nil)
}

@Test @MainActor func homeEffectsFenceExpiryReplacementAndForeignDismissal() async throws {
    let state = ConversationState()
    state.expressionRendererAvailable = true
    let activity = ActionActivityState()
    let effects = HomeEffectsWorkflow(activity: activity)
    effects.bind(state)
    let input = homeEffectInput()
    try await effects.showNotice(.init(text: "先", tone: .warning), durationMS: 500, invocation: input)
    try await effects.showNotice(.init(text: "后", tone: .warning), durationMS: 30000, invocation: input)
    try await effects.updateLight(
        .init(origin: .init(x: 0.5, y: 0.4), initialOpacity: 0.85, intensity: 1), durationMS: 500, invocation: input)
    await #expect(throws: HomeEffectsWorkflow.Error.self) {
        try await effects.dismissNotice(invocation: homeEffectInput())
    }
    await #expect(throws: HomeEffectsWorkflow.Error.self) {
        try await effects.updateLight(nil, invocation: homeEffectInput())
    }
    try await Task.sleep(for: .milliseconds(700))
    #expect(state.decorativeLight == nil && activity.notice?.text == "后")
    effects.stop()
    #expect(activity.notice == nil)
}

@Test @MainActor func noticeVisibilityRestoresRetainedBottomCaptionsAndSleepClearsBoth() {
    let state = ConversationState()
    state.isVoiceActive = true
    state.liveTranscript = "用户说话"
    state.assistantReply = "正在回复"
    #expect(!ConversationCaptionVisibility.user(isListening: true, finalized: false, hasNotice: true))
    #expect(!ConversationCaptionVisibility.reply(hasNotice: true))
    #expect(state.liveTranscript == "用户说话" && state.assistantReply == "正在回复")
    #expect(ConversationCaptionVisibility.user(isListening: true, finalized: false, hasNotice: false))
    #expect(ConversationCaptionVisibility.reply(hasNotice: false))
    #expect(ConversationCaptionVisibility.user(isListening: true, finalized: true, hasNotice: true))
    state.isVoiceActive = false
    #expect(state.liveTranscript.isEmpty && state.assistantReply.isEmpty && !state.transcriptFinalized)
    #expect(state.displayedExpression == .closed)
}

@Test @MainActor func replyEndFadeCannotClearAReplacementOrSleepingSession() async throws {
    let state = ConversationState()
    state.isVoiceActive = true
    let effects = HomeEffectsWorkflow(activity: ActionActivityState())
    effects.bind(state)
    effects.replyDidBegin()
    state.assistantReply = "第一段"
    #expect(state.assistantReplyOpacity == 1)
    effects.replyDidFinish()
    #expect(state.assistantReplyOpacity == 0 && state.assistantReply == "第一段")
    effects.replyDidBegin()
    state.assistantReply = "第二段"
    try await Task.sleep(for: .milliseconds(450))
    #expect(state.assistantReply == "第二段" && state.assistantReplyOpacity == 1)
    effects.replyDidFinish()
    try await Task.sleep(for: .milliseconds(450))
    #expect(state.assistantReply.isEmpty && state.assistantReplyOpacity == 1)
    state.assistantReply = "关闭时的字幕"
    effects.replyDidFinish()
    state.isVoiceActive = false
    effects.replyDidBegin()
    #expect(state.assistantReply.isEmpty && state.liveTranscript.isEmpty)
    effects.stop()
}
