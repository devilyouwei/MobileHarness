import AgentCore
import AppWorkflows
import Foundation
import FunctionContracts
import Testing
import UI

@Test func changingCaptionOwnerDoesNotRevokeParentPlayback() {
    let session = UUID()
    let turn = AgentTurn(ordinal: 1)
    let parent = ActionExecutionContext(
        source: "assistant", sessionID: session, inputID: UUID(), sequence: 1,
        correlationID: turn.id, ordinal: turn.ordinal)
    let child = ActionExecutionContext(
        source: "photographer", sessionID: session, inputID: UUID(), sequence: 2,
        correlationID: turn.id, ordinal: turn.ordinal, taskID: UUID(), taskExecutor: "photographer")
    var presentation = ConversationPresentation()
    let parentAccepted = presentation.accept(parent, update: .beginReply)
    #expect(parentAccepted)
    let childAccepted = presentation.accept(child, update: .beginReply)
    #expect(childAccepted)
    #expect(!presentation.isCurrent(parent))
    #expect(presentation.acceptsPlayback(parent, activeSessions: [session]))
    #expect(presentation.acceptsPlayback(child, activeSessions: [session]))
    #expect(!presentation.acceptsPlayback(parent, activeSessions: []))
    #expect(!presentation.acceptsPlayback(child, activeSessions: [UUID()]))
}

@Test @MainActor func newRecognitionClearsPriorCaptionsAndStartsBelowBeforeFinalPromotion() {
    let state = ConversationState()
    var presentation = ConversationPresentation()
    func accept(_ context: ActionExecutionContext, update: ConversationPresentation.Update, state: ConversationState)
        -> Bool
    {
        presentation.accept(context, update: update, state: state)
    }
    let session = UUID()
    let first = AgentTurn(ordinal: 1)
    let second = AgentTurn(ordinal: 2)
    func context(_ turn: AgentTurn, _ sequence: UInt64, source: String = "speechPerception") -> ActionExecutionContext {
        .init(
            source: source, sessionID: session, inputID: UUID(), sequence: sequence,
            correlationID: turn.id, ordinal: turn.ordinal)
    }
    let initial = context(first, 1)
    #expect(accept(initial, update: .transcript, state: state))
    state.liveTranscript = "上一轮用户"
    #expect(accept(context(first, 2), update: .finishTranscript, state: state))
    state.finishUserTranscript()
    #expect(accept(context(first, 1, source: "assistant"), update: .beginReply, state: state))
    state.assistantReply = "上一轮回复"
    #expect(state.transcriptFinalized)
    // Confirmed onset arrives before any ASR text.
    let onset = context(second, 3)
    #expect(accept(onset, update: .voiceState, state: state))
    #expect(state.liveTranscript.isEmpty && state.assistantReply.isEmpty && !state.transcriptFinalized)
    let preview = context(second, 4)
    #expect(accept(preview, update: .transcript, state: state))
    state.liveTranscript = "新的"
    #expect(!accept(onset, update: .voiceState, state: state))
    #expect(!accept(context(first, 99), update: .finishTranscript, state: state))
    #expect(!accept(context(second, 0), update: .voiceState, state: state))
    #expect(state.liveTranscript == "新的" && !state.transcriptFinalized)
    #expect(accept(context(second, 5), update: .transcript, state: state))
    state.liveTranscript = "新的用户输入"
    #expect(accept(context(second, 6), update: .finishTranscript, state: state))
    state.finishUserTranscript()
    #expect(state.transcriptFinalized && state.liveTranscript == "新的用户输入")
    #expect(!accept(context(second, 7), update: .transcript, state: state))
    #expect(accept(context(second, 2, source: "assistant"), update: .beginReply, state: state))
    state.assistantReply = "当前回复"
    #expect(state.transcriptFinalized && state.liveTranscript == "新的用户输入")
    #expect(state.assistantReply == "当前回复")
    #expect(presentation.replyTurn == second)
}

@Test @MainActor func firstTranscriptCanResetCaptionsWithoutAnEarlierOnsetUpdate() {
    let state = ConversationState()
    var presentation = ConversationPresentation()
    func accept(_ context: ActionExecutionContext, update: ConversationPresentation.Update, state: ConversationState)
        -> Bool
    {
        presentation.accept(context, update: update, state: state)
    }
    state.liveTranscript = "旧输入"
    state.assistantReply = "旧回复"
    state.finishUserTranscript()
    let turn = AgentTurn(ordinal: 1)
    let context = ActionExecutionContext(
        source: "speechPerception", sessionID: UUID(), inputID: UUID(), sequence: 1,
        correlationID: turn.id, ordinal: turn.ordinal)
    #expect(accept(context, update: .transcript, state: state))
    state.liveTranscript = "新输入"
    #expect(!state.transcriptFinalized && state.assistantReply.isEmpty)
    #expect(!accept(context, update: .transcript, state: state))
    #expect(state.liveTranscript == "新输入")
}
