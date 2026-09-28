import Foundation

/// Transport-owned PCM. ModelKit conversion belongs to composition/perception, never Gateway.
public struct AudioInput: Sendable {
    public let samples: Data
    public let sequence: UInt64
    public let timestamp: TimeInterval
    public var sampleCount: Int { samples.count / 4 }
    public init(samples: Data, sequence: UInt64, timestamp: TimeInterval) throws {
        guard !samples.isEmpty, samples.count <= 64_000, samples.count.isMultiple(of: 4),
            timestamp.isFinite, timestamp >= 0
        else { throw CommunicationError.invalidPayload }
        self.samples = samples
        self.sequence = sequence
        self.timestamp = timestamp
    }
}

public enum SpeechPhase: String, Codable, Sendable { case listening, speaking, processing, empty }
public typealias PerceptionObservation = AgentMessage

public enum AgentMessage: Codable, Sendable, Equatable {
    case transcript(String, final: Bool)
    case speechPhase(SpeechPhase)
    case pose(PoseObservation)
    case speechSynthesis(SpeechSynthesisInput)
    case cancelSpeech(UUID)
    public var contract: String {
        switch self {
        case .transcript(_, true): "speech.final"
        case .transcript(_, false): "speech.partial"
        case .speechPhase: "speech.phase"
        case .pose: "vision.pose"
        case .speechSynthesis: "speech.synthesize"
        case .cancelSpeech: "speech.cancel"
        }
    }
    public var isState: Bool { contract == "speech.partial" || contract == "vision.pose" }
    public func validatedSize() throws -> Int {
        switch self {
        case .transcript(let text, let final):
            guard text.utf8.count <= (final ? 4096 : 16300), !final || !text.isEmpty else {
                throw CommunicationError.invalidPayload
            }
        case .speechSynthesis(let request): try request.validate()
        case .cancelSpeech, .speechPhase: break
        case .pose(let pose): try pose.validate()
        }
        let count = try JSONEncoder().encode(self).count
        guard count <= (contract == "vision.pose" ? 262_144 : 16_384) else {
            throw CommunicationError.invalidPayload
        }
        return count
    }
}

/// Upright, unmirrored pixel coordinates; display quantization is a consumer policy.
public struct PoseObservation: Codable, Equatable, Sendable {
    public struct Joint: Codable, Equatable, Sendable {
        public let x: Float
        public let y: Float
        public let confidence: Float
        public init(x: Float, y: Float, confidence: Float) {
            self.x = x
            self.y = y
            self.confidence = confidence
        }
    }
    public let width: Int
    public let height: Int
    public let sequence: UInt64
    public let timestamp: TimeInterval
    public let rotation: Int
    public let people: [[Joint]]
    public init(width: Int, height: Int, sequence: UInt64, timestamp: TimeInterval, rotation: Int, people: [[Joint]])
        throws
    {
        self.width = width
        self.height = height
        self.sequence = sequence
        self.timestamp = timestamp
        self.rotation = rotation
        self.people = people
        try validate()
    }
    public func validate() throws {
        guard (1...4096).contains(width), (1...4096).contains(height), (0...3).contains(rotation),
            timestamp.isFinite, timestamp >= 0, people.count <= 300,
            people.allSatisfy({
                $0.count == 17
                    && $0.allSatisfy {
                        $0.x.isFinite && $0.y.isFinite && $0.confidence.isFinite && (0...1).contains($0.confidence)
                    }
            })
        else { throw CommunicationError.invalidPayload }
    }
}

/// A synthesis unit selected by its originating Agent; audio IDs are application-generated.
public struct SpeechSynthesisInput: Codable, Sendable, Equatable {
    public let audioID: UUID
    public let text: String
    public let locale: String
    public init(audioID: UUID = UUID(), text: String, locale: String = "auto") throws {
        self.audioID = audioID
        self.text = text
        self.locale = locale
        try validate()
    }
    public func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            text.utf8.count <= 2000, ["auto", "zh-CN", "en-US"].contains(locale)
        else { throw CommunicationError.invalidPayload }
    }
}
