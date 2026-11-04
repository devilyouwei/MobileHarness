import Actions
import AgentCore
import Agents
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import Testing

@testable import UI

@Test func changingCaptionOwnerDoesNotRevokeParentPlayback() {
    let session = UUID().uuidString
    let turn = AgentTurn(id: UUID().uuidString, ordinal: 1)
    let parent = ActionExecutionContext(
        source: "assistant", sessionID: session, inputID: UUID().uuidString, sequence: 1,
        correlationID: turn.id, ordinal: turn.ordinal)
    let child = ActionExecutionContext(
        source: "photographer", sessionID: session, inputID: UUID().uuidString, sequence: 2,
        correlationID: turn.id, ordinal: turn.ordinal, taskID: UUID().uuidString,
        taskExecutor: "photographer")
    var presentation = ConversationPresentation()
    let parentAccepted = presentation.accept(parent, update: .beginReply)
    #expect(parentAccepted)
    let childAccepted = presentation.accept(child, update: .beginReply)
    #expect(childAccepted)
    #expect(!presentation.isCurrent(parent))
    #expect(presentation.acceptsPlayback(parent, activeSessions: [session]))
    #expect(presentation.acceptsPlayback(child, activeSessions: [session]))
    #expect(!presentation.acceptsPlayback(parent, activeSessions: []))
    #expect(!presentation.acceptsPlayback(child, activeSessions: [UUID().uuidString]))
}

@Test @MainActor func newRecognitionClearsPriorCaptionsAndStartsBelowBeforeFinalPromotion() {
    let state = ConversationState()
    var presentation = ConversationPresentation()
    func accept(_ context: ActionExecutionContext, update: ConversationPresentation.Update, state: ConversationState)
        -> Bool
    {
        presentation.accept(context, update: update, state: state)
    }
    let session = UUID().uuidString
    let first = AgentTurn(id: UUID().uuidString, ordinal: 1)
    let second = AgentTurn(id: UUID().uuidString, ordinal: 2)
    func context(_ turn: AgentTurn, _ sequence: UInt64, source: String = "speechPerception") -> ActionExecutionContext {
        .init(
            source: source, sessionID: session, inputID: UUID().uuidString, sequence: sequence,
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
    #expect(presentation.replyTurn == ConversationTurn(id: second.id, ordinal: second.ordinal))
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
    let turn = AgentTurn(id: UUID().uuidString, ordinal: 1)
    let context = ActionExecutionContext(
        source: "speechPerception", sessionID: UUID().uuidString, inputID: UUID().uuidString,
        sequence: 1,
        correlationID: turn.id, ordinal: turn.ordinal)
    #expect(accept(context, update: .transcript, state: state))
    state.liveTranscript = "新输入"
    #expect(!state.transcriptFinalized && state.assistantReply.isEmpty)
    #expect(!accept(context, update: .transcript, state: state))
    #expect(state.liveTranscript == "新输入")
}

@Test func userOffRejectsLateReplyCaptionAndPlaybackUntilFreshRecognition() {
    let session = UUID().uuidString
    let turn = AgentTurn(id: UUID().uuidString, ordinal: 1)
    func context(_ turn: AgentTurn, _ sequence: UInt64, source: String = "assistant") -> ActionExecutionContext {
        .init(
            source: source, sessionID: session, inputID: UUID().uuidString, sequence: sequence,
            correlationID: turn.id, ordinal: turn.ordinal)
    }
    var presentation = ConversationPresentation()
    func accept(_ context: ActionExecutionContext, update: ConversationPresentation.Update) -> Bool {
        presentation.accept(context, update: update)
    }
    #expect(accept(context(turn, 1, source: "speechPerception"), update: .transcript))
    #expect(accept(context(turn, 1), update: .beginReply))
    presentation.suspendReplies()
    #expect(!accept(context(turn, 2), update: .reply))
    #expect(!accept(context(turn, 3), update: .expression))
    #expect(!presentation.acceptsPlayback(context(turn, 4), activeSessions: [session]))
    presentation.beginRecognitionScope()
    #expect(!accept(context(turn, 5), update: .reply))
    #expect(!presentation.acceptsPlayback(context(turn, 6), activeSessions: [session]))
    let next = AgentTurn(id: UUID().uuidString, ordinal: 2)
    #expect(accept(context(next, 2, source: "speechPerception"), update: .transcript))
    #expect(accept(context(next, 7), update: .beginReply))
    #expect(presentation.acceptsPlayback(context(next, 8), activeSessions: [session]))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func uiExpressionWaitsForRendererAndRejectsLateCompletionAfterReplacement() async throws {
    let state = ConversationState()
    state.isVoiceActive = true
    state.expressionRendererAvailable = true
    let renderer = ConversationExpressionPresentation(state: state)
    renderer.setBase(.smile)
    var completed = false
    let first = Task {
        try await renderer.perform(.happy, owner: "first")
        completed = true
    }
    while state.expressionTransitionID == nil { await Task.yield() }
    let firstID = try #require(state.expressionTransitionID)
    let late = try #require(state.expressionAnimationCompletion)
    #expect(!completed && state.expression == .happy)
    late(firstID, true)
    try await first.value
    #expect(completed)
    let restore = Task { try await renderer.restore(owner: "first", accepts: true) }
    while state.expressionTransitionID == nil { await Task.yield() }
    let restoreID = try #require(state.expressionTransitionID)
    late(firstID, true)
    #expect(state.expressionTransitionID == restoreID)
    state.expressionAnimationCompletion?(restoreID, true)
    try await restore.value
    #expect(state.expression == .smile && !state.expressionEmphasized)
    #expect(state.expressionTransitionID == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func uiExpressionCancellationJoinsWaitAndPreservesRendererFailure() async throws {
    let state = ConversationState()
    state.isVoiceActive = true
    let renderer = ConversationExpressionPresentation(state: state)
    await #expect(throws: ConversationExpressionError.rendererUnavailable) {
        try await renderer.perform(.happy, owner: "unavailable")
    }
    renderer.resetExpression()
    state.expressionRendererAvailable = true
    let operation = Task { try await renderer.perform(.happy, owner: "cancelled") }
    while state.expressionTransitionID == nil { await Task.yield() }
    let staleID = try #require(state.expressionTransitionID)
    let late = try #require(state.expressionAnimationCompletion)
    operation.cancel()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(state.expressionTransitionID == nil)
    renderer.resetExpression()
    late(staleID, true)
    #expect(state.expression == nil && state.expressionTransitionID == nil)
}

@Test @MainActor func uiSettingsRejectsProjectionFromReplacedDraft() {
    let state = SettingsState(initial: CloudSettingsDraft(enabled: true, url: "https://old", key: "old", model: "old"))
    let previous = state.revision
    state.url = "https://new"
    #expect(!state.presentNotice("stale", revision: previous))
    #expect(!state.presentFailure("stale", revision: previous))
    #expect(
        !state.presentRestored(
            CloudSettingsDraft(enabled: false, url: "https://old", key: "old", model: "old"), revision: previous))
    #expect(state.url == "https://new" && state.modelCatalogs.isEmpty && state.error == nil)
    #expect(state.presentNotice("current", revision: state.revision))
    #expect(state.modelCatalogs.isEmpty && state.notice == "current")
}

@Test func replyWaitingKeepsIndependentSequenceAndRejectsOldDecision() {
    let session = UUID().uuidString
    let turn = AgentTurn(id: UUID().uuidString, ordinal: 1)
    func context(_ sequence: UInt64, decision: String = "first") -> ActionExecutionContext {
        .init(
            source: "assistant", sessionID: session, inputID: "input", sequence: sequence,
            correlationID: turn.id, ordinal: turn.ordinal, decisionID: decision)
    }
    var presentation = ConversationPresentation()
    func accept(_ context: ActionExecutionContext, update: ConversationPresentation.Update) -> Bool {
        presentation.accept(context, update: update)
    }
    #expect(accept(context(1), update: .beginReply))
    #expect(accept(context(2), update: .replyWaiting))
    #expect(accept(context(3), update: .reply))
    #expect(accept(context(4), update: .replyWaiting))
    #expect(!accept(context(2), update: .replyWaiting))
    #expect(accept(context(5, decision: "second"), update: .beginReply))
    #expect(!accept(context(6), update: .replyWaiting))
    #expect(accept(context(7, decision: "second"), update: .replyWaiting))
    presentation.suspendReplies()
    #expect(!accept(context(8, decision: "second"), update: .replyWaiting))
}
