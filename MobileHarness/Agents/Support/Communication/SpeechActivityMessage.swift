import AgentCore
import Foundation

enum SpeechSignalClock {
    private static let origin = ContinuousClock.now
    static func offset(at instant: ContinuousClock.Instant) -> Duration { origin.duration(to: instant) }
}

/// Voice-activity facts from one capture generation.
public struct SpeechActivity: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case captureStarted, captureStopped, onsetStarted, onsetCleared, onsetConfirmed, vadProgress
    }

    public static let contract = "perception.speech.activity.v1"
    public static let channel = "perception.speech.activity"
    public static let progressWindowCount = 64

    public let kind: Kind
    public let generation: String
    public let utterance: String?
    public let sequence: UInt64?
    public let onsetRevision: UInt64?
    /// Capture time of the oldest of the latest 64 complete VAD windows.
    public let oldestWindow: Duration?
    /// For an onset, the oldest of the 64 complete windows preceding its first candidate.
    public let oldestWindowBeforeOnset: Duration?

    public init(
        _ kind: Kind, generation: String, utterance: String? = nil,
        sequence: UInt64? = nil, oldestWindow: Duration? = nil, onsetRevision: UInt64? = nil,
        oldestWindowBeforeOnset: Duration? = nil
    ) {
        self.kind = kind
        self.generation = generation
        self.utterance = utterance
        self.sequence = sequence
        self.onsetRevision = onsetRevision
        self.oldestWindow = oldestWindow
        self.oldestWindowBeforeOnset = oldestWindowBeforeOnset
    }

    func validate() throws {
        guard (1...128).contains(generation.utf8.count),
            utterance.map({ (1...128).contains($0.utf8.count) }) ?? true,
            (kind == .onsetConfirmed) == (utterance != nil),
            (kind == .vadProgress) == (sequence != nil),
            oldestWindow == nil || (sequence ?? 0) >= Self.progressWindowCount,
            ([.captureStarted, .captureStopped].contains(kind)) == (onsetRevision == nil),
            oldestWindowBeforeOnset == nil || kind == .onsetStarted || kind == .onsetConfirmed,
            sequence != 0
        else { throw CommunicationError.invalidPayload }
    }

    public func message() -> AgentMessage {
        .init(
            contract: Self.contract, content: self, maximumBytes: 1024, event: kind.rawValue,
            validate: { try $0.validate() })
    }
}

extension InputPayload {
    public var speechActivity: SpeechActivity? {
        guard case .observation(let message) = self, message.contract == SpeechActivity.contract else { return nil }
        return message.content(as: SpeechActivity.self)
    }
}
