import ActionRuntime
import AgentCore
import Foundation
import ToolRuntime

/// Bounded acceptance policy for UI handlers. No device, view, queue or callback ownership.
public struct ConversationPresentation: Sendable {
    public enum Update: Hashable, Sendable {
        case transcript, finishTranscript, voiceState, beginReply, reply, expression
    }
    public private(set) var turn: ConversationTurn?
    public private(set) var transcriptClosed = false
    private var replyBegun = false
    private var sequences: [Update: UInt64] = [:]
    public init() {}

    public func isCurrent(_ envelope: OutputEnvelope) -> Bool {
        envelope.turn != nil && envelope.turn == turn
    }

    /// Caller first validates active session. Only onset-related updates can advance the turn.
    public mutating func accept(_ envelope: OutputEnvelope, update: Update) -> Bool {
        accept(source: envelope.source.rawValue, turn: envelope.turn, sequence: envelope.sequence, update: update)
    }
    private mutating func accept(source: String, turn incomingTurn: ConversationTurn?, sequence: UInt64, update: Update)
        -> Bool
    {
        guard let incoming = incomingTurn, incoming.ordinal > 0, sequence > 0 else { return false }
        let speech = update == .transcript || update == .finishTranscript || update == .voiceState
        guard source == (speech ? AgentID.speechPerception.rawValue : AgentID.assistant.rawValue) else { return false }
        if incoming != turn {
            guard incoming.ordinal > (turn?.ordinal ?? 0),
                speech || update == .beginReply
            else { return false }
            turn = incoming
            transcriptClosed = false
            replyBegun = false
            sequences.removeAll(keepingCapacity: true)
        }
        guard sequence > (sequences[update] ?? 0) else { return false }
        if update == .transcript && transcriptClosed { return false }
        if update == .beginReply && replyBegun { return false }
        if update == .reply || update == .expression {
            guard replyBegun, sequence > (sequences[.beginReply] ?? 0) else { return false }
        }
        sequences[update] = sequence
        if update == .finishTranscript { transcriptClosed = true }
        if update == .beginReply { replyBegun = true }
        return true
    }
}

extension ConversationPresentation {
    public func isCurrent(_ context: ActionExecutionContext) -> Bool {
        context.correlationID != nil && context.correlationID == turn?.id && context.ordinal == turn?.ordinal
    }
    public func isCurrent(_ context: ToolExecutionContext) -> Bool {
        context.correlationID != nil && context.correlationID == turn?.id && context.ordinal == turn?.ordinal
    }
    public mutating func accept(_ context: ActionExecutionContext, update: Update) -> Bool {
        accept(
            source: context.source, sequence: context.sequence,
            id: context.correlationID, ordinal: context.ordinal, update: update)
    }
    public mutating func accept(_ context: ToolExecutionContext, update: Update) -> Bool {
        accept(
            source: context.source, sequence: context.sequence,
            id: context.correlationID, ordinal: context.ordinal, update: update)
    }
    private mutating func accept(
        source: String, sequence: UInt64, id: UUID?, ordinal: UInt64?, update: Update
    ) -> Bool {
        guard let id, let ordinal else { return false }
        return accept(
            source: source, turn: ConversationTurn(id: id, ordinal: ordinal), sequence: sequence, update: update)
    }
}
