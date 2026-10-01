import AgentCore
import Foundation

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

    /// Caller first validates active session. Only onset-related Actions can advance the turn.
    public mutating func accept(_ envelope: OutputEnvelope, update: Update) -> Bool {
        guard let incoming = envelope.turn, incoming.ordinal > 0, envelope.sequence > 0 else { return false }
        let speech = update == .transcript || update == .finishTranscript || update == .voiceState
        guard envelope.source == (speech ? .speechPerception : .assistant) else { return false }
        if incoming != turn {
            guard incoming.ordinal > (turn?.ordinal ?? 0),
                speech || update == .beginReply
            else { return false }
            turn = incoming
            transcriptClosed = false
            replyBegun = false
            sequences.removeAll(keepingCapacity: true)
        }
        guard envelope.sequence > (sequences[update] ?? 0) else { return false }
        if update == .transcript && transcriptClosed { return false }
        if update == .beginReply && replyBegun { return false }
        if update == .reply || update == .expression {
            guard replyBegun, envelope.sequence > (sequences[.beginReply] ?? 0) else { return false }
        }
        sequences[update] = envelope.sequence
        if update == .finishTranscript { transcriptClosed = true }
        if update == .beginReply { replyBegun = true }
        return true
    }
}
