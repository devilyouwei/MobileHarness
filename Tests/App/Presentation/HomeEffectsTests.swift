import Actions
import Agents
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import Testing

@testable import UI

@Test @MainActor func homeEffectsKeepConsentAndErrorEvidenceIndependent() async throws {
    let activity = HomeNoticeState()
    let state = ConversationState()
    state.expressionRendererAvailable = true
    let effects = HomeEffectsWorkflow(notices: activity)
    effects.bind(state)
    let owner = PresentationOwner(source: "assistant", session: UUID().uuidString)
    try await effects.updateLight(
        .init(origin: .init(x: 0.1, y: 0.8), initialOpacity: 0.85, intensity: 1), owner: owner)
    #expect(state.decorativeLight?.origin == .init(x: 0.1, y: 0.8))
    #expect(!state.isVoiceActive && state.displayedExpression == .closed && state.listeningAnimationID == nil)
    try await effects.showNotice(.init(text: "提醒", tone: .info), owner: owner)
    #expect(activity.visibleNotice?.text == "提醒")
    activity.offerToast(.init(title: "失败", source: "assistant", message: "真实异常"))
    #expect(activity.visibleNotice?.text == "真实异常")
    await #expect(throws: HomeEffectsWorkflow.Error.self) {
        try await effects.showNotice(.init(text: "不能覆盖异常", tone: .warning), owner: owner)
    }
    try await effects.dismissNotice(owner: owner)
    #expect(activity.errorToast != nil && activity.notice == nil)
    effects.stop()
    #expect(state.decorativeLight == nil && activity.errorToast != nil)
}

@Test @MainActor func homeEffectsFenceExpiryReplacementAndForeignDismissal() async throws {
    let state = ConversationState()
    state.expressionRendererAvailable = true
    let activity = HomeNoticeState()
    let effects = HomeEffectsWorkflow(notices: activity)
    effects.bind(state)
    let owner = PresentationOwner(source: "assistant", session: UUID().uuidString)
    try await effects.showNotice(.init(text: "先", tone: .warning), durationMS: 500, owner: owner)
    try await effects.showNotice(.init(text: "后", tone: .warning), durationMS: 30000, owner: owner)
    try await effects.updateLight(
        .init(origin: .init(x: 0.5, y: 0.4), initialOpacity: 0.85, intensity: 1), durationMS: 500, owner: owner)
    await #expect(throws: HomeEffectsWorkflow.Error.self) {
        try await effects.dismissNotice(owner: PresentationOwner(source: "assistant", session: UUID().uuidString))
    }
    await #expect(throws: HomeEffectsWorkflow.Error.self) {
        try await effects.updateLight(nil, owner: PresentationOwner(source: "assistant", session: UUID().uuidString))
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

@Test @MainActor func replyEndRetainsCaptionsUntilTheirOwnerClearsOrSessionCloses() async throws {
    let state = ConversationState()
    state.isVoiceActive = true
    let effects = HomeEffectsWorkflow(notices: HomeNoticeState())
    effects.bind(state)
    effects.replyDidBegin()
    state.assistantReply = "第一段"
    #expect(state.assistantReplyOpacity == 1)
    effects.replyDidFinish()
    #expect(state.assistantReplyOpacity == 1 && state.assistantReply == "第一段")
    effects.replyDidBegin()
    state.assistantReply = "第二段"
    try await Task.sleep(for: .milliseconds(450))
    #expect(state.assistantReply == "第二段" && state.assistantReplyOpacity == 1)
    effects.replyDidFinish()
    try await Task.sleep(for: .milliseconds(450))
    #expect(state.assistantReply == "第二段" && state.assistantReplyOpacity == 1)
    state.assistantReply = "关闭时的字幕"
    effects.replyDidFinish()
    state.isVoiceActive = false
    effects.replyDidBegin()
    #expect(state.assistantReply.isEmpty)
    state.resetCaptions()
    #expect(state.assistantReply.isEmpty && state.liveTranscript.isEmpty)
    effects.stop()
}

@Test(arguments: ["", "本轮回复"]) @MainActor
func listeningRestorationRetainsFinalUserCaptionEvenWithoutReplyText(reply: String) async {
    let state = ConversationState()
    state.isVoiceActive = true
    state.presentTranscript("本轮用户输入")
    state.finishUserTranscript()
    state.appendReply(reply)
    let effects = HomeEffectsWorkflow(notices: HomeNoticeState())
    effects.bind(state)

    effects.replyDidFinish()

    #expect(state.liveTranscript == "本轮用户输入" && state.transcriptFinalized)
    #expect(state.isVoiceActive && state.assistantReply == reply)
    await effects.stopAndWait()
}

@Test @MainActor func listeningRestorationPreservesNextPartialTranscriptThroughReplyCompletion() async throws {
    let state = ConversationState()
    state.isVoiceActive = true
    state.presentTranscript("下一轮正在说话")
    state.appendReply("上一轮回复")
    let effects = HomeEffectsWorkflow(notices: HomeNoticeState())
    effects.bind(state)

    effects.replyDidFinish()
    #expect(state.liveTranscript == "下一轮正在说话" && !state.transcriptFinalized)
    try await Task.sleep(for: .milliseconds(450))
    #expect(state.assistantReply == "上一轮回复")
    #expect(state.liveTranscript == "下一轮正在说话" && !state.transcriptFinalized)
    await effects.stopAndWait()
}

@Test @MainActor func transientToastRemainsIndependentOfReplyCaptionsAndErrorNotice() async throws {
    let activity = HomeNoticeState()
    let state = ConversationState()
    state.assistantReply = "正在回复"
    state.liveTranscript = "嗯嗯"
    let effects = HomeEffectsWorkflow(notices: activity)
    effects.bind(state)
    let owner = PresentationOwner(source: "assistant.input", session: "discard")
    try await effects.showNotice(
        .init(text: "已丢弃：嗯嗯", tone: .info, placement: .toast), durationMS: 500, owner: owner)
    #expect(activity.transientToast?.text == "已丢弃：嗯嗯")
    #expect(activity.visibleNotice == nil)
    #expect(state.assistantReply == "正在回复" && state.liveTranscript == "嗯嗯")
    activity.offerToast(.init(title: "失败", source: "assistant", message: "真实异常"))
    try await effects.showNotice(
        .init(text: "已丢弃：好的", tone: .info, placement: .toast), durationMS: 500, owner: owner)
    #expect(activity.visibleNotice?.text == "真实异常")
    #expect(activity.transientToast?.text == "已丢弃：好的")
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while activity.transientToast != nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(activity.transientToast == nil && activity.errorToast != nil)
    await effects.stopAndWait()
}
