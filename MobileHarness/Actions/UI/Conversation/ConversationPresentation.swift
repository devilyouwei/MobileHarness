import Foundation
import FunctionContracts
import StorageCore
import UI

/// Recognition and replies have independent identities: a queued task may reply after a later utterance.
/// Session, active task and registered function permissions are checked by the calling Agents boundary.
public struct ConversationPresentation: Sendable {
    public enum Update: Hashable, Sendable {
        case transcript, finishTranscript, voiceState, beginReply, clearReply, reply, expression, replyWaiting
    }
    public private(set) var turn: ConversationTurn?
    public private(set) var replyTurn: ConversationTurn?
    public private(set) var replySource: String?
    public private(set) var replyDecisionID: String?
    public private(set) var replyTaskID: String?
    public private(set) var transcriptClosed = false
    private var replyInputID: String?
    private var lastCaptionStart: ConversationTurn?
    // One current retired request per known producer; shares the existing 32-producer bound.
    private var retiredReplyInputs: [String: String] = [:]
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
        lastCaptionStart = nil
        transcriptClosed = false
        for key in [Update.transcript, .finishTranscript, .voiceState] { sequences[key] = nil }
    }

    public func isRecognitionCurrent(_ context: ActionExecutionContext) -> Bool {
        context.correlationID != nil && context.correlationID == turn?.id && context.ordinal == turn?.ordinal
    }
    public func isCurrent(_ context: ActionExecutionContext) -> Bool {
        context.correlationID != nil && context.correlationID == replyTurn?.id && context.ordinal == replyTurn?.ordinal
            && context.source == replySource && context.decisionID == replyDecisionID && context.taskID == replyTaskID
    }
    public mutating func accept(_ context: ActionExecutionContext, update: Update, retiringInputID: String? = nil)
        -> Bool
    {
        guard let id = context.correlationID, let ordinal = context.ordinal else { return false }
        return accept(
            source: context.source, incoming: ConversationTurn(id: id, ordinal: ordinal),
            sequence: context.sequence, decisionID: context.decisionID, taskID: context.taskID,
            inputID: context.inputID,
            retiringInputID: retiringInputID, update: update)
    }
    private mutating func accept(
        source: String, incoming: ConversationTurn?, sequence: UInt64,
        decisionID: String?, taskID: String?, inputID: String, retiringInputID: String?, update: Update
    ) -> Bool {
        guard let incoming, incoming.ordinal > 0, sequence > 0 else { return false }
        if update == .clearReply {
            guard incoming.ordinal > (lastCaptionStart?.ordinal ?? 0),
                sequence > (sequences[.clearReply] ?? 0),
                replySource == nil || replySource == source,
                producerSequences[source] != nil || producerSequences.count < 32
            else { return false }
            lastCaptionStart = incoming
            let retired = retiringInputID ?? replyInputID
            if let retired { retiredReplyInputs[source] = retired }
            producerSequences[source] = max(producerSequences[source] ?? 0, sequence)
            sequences[.clearReply] = sequence
            // A later genuinely new reply wins over a delayed clear of a previous request.
            if (sequences[.beginReply] ?? 0) > sequence, replyInputID != retired { return false }
            replyTurn = nil
            replyInputID = nil
            replySource = nil
            replyDecisionID = nil
            replyTaskID = nil
            return true
        }
        let recognition = update == .transcript || update == .finishTranscript || update == .voiceState
        if recognition {
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
            if update == .beginReply {
                guard inputID != retiredReplyInputs[source], sequence > (producerSequences[source] ?? 0),
                    incoming != replyTurn || source != replySource || decisionID != replyDecisionID
                        || taskID != replyTaskID
                else { return false }
                guard producerSequences[source] != nil || producerSequences.count < 32 else { return false }
                producerSequences[source] = sequence
                replyTurn = incoming
                replyInputID = inputID
                replySource = source
                replyDecisionID = decisionID
                replyTaskID = taskID
                for key in [Update.beginReply, .reply, .expression, .replyWaiting] { sequences[key] = nil }
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
