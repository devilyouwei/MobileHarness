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
    let effects = HomeEffectsWorkflow()
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
    let effects = HomeEffectsWorkflow()
    effects.bind(state)

    effects.replyDidFinish()

    #expect(state.liveTranscript == "本轮用户输入" && state.transcriptFinalized)
    #expect(state.isVoiceActive && state.assistantReply == reply)
    effects.stopAndWait()
}

@Test @MainActor func listeningRestorationPreservesNextPartialTranscriptThroughReplyCompletion() async throws {
    let state = ConversationState()
    state.isVoiceActive = true
    state.presentTranscript("下一轮正在说话")
    state.appendReply("上一轮回复")
    let effects = HomeEffectsWorkflow()
    effects.bind(state)

    effects.replyDidFinish()
    #expect(state.liveTranscript == "下一轮正在说话" && !state.transcriptFinalized)
    try await Task.sleep(for: .milliseconds(450))
    #expect(state.assistantReply == "上一轮回复")
    #expect(state.liveTranscript == "下一轮正在说话" && !state.transcriptFinalized)
    effects.stopAndWait()
}
