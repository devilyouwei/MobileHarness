import AgentCore
import Foundation
import FunctionContracts
import Storage
import UI

/// Recognition and replies have independent identities: a queued task may reply after a later utterance.
/// Session, active task and registered function permissions are checked by the calling host/Gateway.
public struct ConversationPresentation: Sendable {
    public enum Update: Hashable, Sendable {
        case transcript, finishTranscript, voiceState, beginReply, reply, expression
    }
    public private(set) var turn: AgentTurn?
    public private(set) var replyTurn: AgentTurn?
    public private(set) var replySource: String?
    public private(set) var replyDecisionID: String?
    public private(set) var replyTaskID: String?
    public private(set) var transcriptClosed = false
    private var repliesEnabled = true
    private var cancelledTurns: [String] = []
    private var sequences: [Update: UInt64] = [:]
    private var producerSequences: [String: UInt64] = [:]
    public init() {}
    /// Caption ownership is independent of the lifetime of accepted Speech Channel work.
    public func acceptsPlayback(_ context: ActionExecutionContext, activeSessions: Set<String>) -> Bool {
        repliesEnabled && activeSessions.contains(context.sessionID)
            && !(context.correlationID.map { cancelledTurns.contains($0) } ?? false)
    }
    public mutating func suspendReplies() {
        repliesEnabled = false
        for id in [turn?.id, replyTurn?.id].compactMap({ $0 }) where !cancelledTurns.contains(id) {
            cancelledTurns.append(id)
        }
        cancelledTurns = Array(cancelledTurns.suffix(32))
    }
    public mutating func beginRecognitionScope() {
        repliesEnabled = true
        turn = nil
        transcriptClosed = false
        for key in [Update.transcript, .finishTranscript, .voiceState] { sequences[key] = nil }
    }

    public func isCurrent(_ envelope: OutputEnvelope) -> Bool {
        envelope.turn != nil && envelope.turn == replyTurn && envelope.source.rawValue == replySource
            && envelope.roundID == replyDecisionID && envelope.taskScope?.id == replyTaskID
    }
    public func isRecognitionCurrent(_ context: ActionExecutionContext) -> Bool {
        context.correlationID != nil && context.correlationID == turn?.id && context.ordinal == turn?.ordinal
    }
    public func isCurrent(_ context: ActionExecutionContext) -> Bool {
        context.correlationID != nil && context.correlationID == replyTurn?.id && context.ordinal == replyTurn?.ordinal
            && context.source == replySource && context.decisionID == replyDecisionID && context.taskID == replyTaskID
    }
    public mutating func accept(_ envelope: OutputEnvelope, update: Update) -> Bool {
        accept(
            source: envelope.source.rawValue, incoming: envelope.turn, sequence: envelope.sequence,
            decisionID: envelope.roundID, taskID: envelope.taskScope?.id,
            authorizedTask: envelope.taskScope?.executor == envelope.source,
            update: update)
    }
    public mutating func accept(_ context: ActionExecutionContext, update: Update) -> Bool {
        guard let id = context.correlationID, let ordinal = context.ordinal else { return false }
        return accept(
            source: context.source, incoming: AgentTurn(id: id, ordinal: ordinal),
            sequence: context.sequence, decisionID: context.decisionID, taskID: context.taskID,
            authorizedTask: context.taskID != nil && context.taskExecutor == context.source, update: update)
    }
    /// Clear the previous visual round only after accepting a new recognition identity.
    @MainActor public mutating func accept(
        _ context: ActionExecutionContext, update: Update, state: ConversationState
    ) -> Bool {
        let previous = turn
        guard accept(context, update: update) else { return false }
        if turn != previous { state.resetCaptions() }
        return true
    }

    private mutating func accept(
        source: String, incoming: AgentTurn?, sequence: UInt64,
        decisionID: String?, taskID: String?, authorizedTask: Bool, update: Update
    ) -> Bool {
        guard let incoming, incoming.ordinal > 0, sequence > 0 else { return false }
        let recognition = update == .transcript || update == .finishTranscript || update == .voiceState
        if recognition {
            guard source == "speechPerception" else { return false }
            if incoming != turn {
                guard incoming.ordinal > (turn?.ordinal ?? 0) else { return false }
                turn = incoming
                transcriptClosed = false
                for key in [Update.transcript, .finishTranscript, .voiceState] { sequences[key] = nil }
            }
            guard sequence > (sequences[update] ?? 0) else { return false }
            if update == .transcript && transcriptClosed { return false }
            if update == .finishTranscript { transcriptClosed = true }
        } else {
            guard repliesEnabled, !cancelledTurns.contains(incoming.id) else { return false }
            guard source == "assistant" || authorizedTask else { return false }
            if update == .beginReply {
                guard sequence > (producerSequences[source] ?? 0),
                    incoming != replyTurn || source != replySource || decisionID != replyDecisionID
                        || taskID != replyTaskID
                else { return false }
                guard producerSequences[source] != nil || producerSequences.count < 32 else { return false }
                producerSequences[source] = sequence
                replyTurn = incoming
                replySource = source
                replyDecisionID = decisionID
                replyTaskID = taskID
                for key in [Update.beginReply, .reply, .expression] { sequences[key] = nil }
            } else {
                guard incoming == replyTurn, source == replySource, decisionID == replyDecisionID,
                    taskID == replyTaskID,
                    sequence > (sequences[.beginReply] ?? 0)
                else { return false }
            }
            guard sequence > (sequences[update] ?? 0) else { return false }
        }
        if !recognition { producerSequences[source] = max(producerSequences[source] ?? 0, sequence) }
        sequences[update] = sequence
        return true
    }
}
