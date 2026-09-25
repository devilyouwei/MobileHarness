import Foundation

public struct JudgeRequest: Sendable {
    public let context: InferenceContext
    public let text: String
    public let candidates: [String]
    public init(text: String, candidates: [String], context: InferenceContext = InferenceContext()) throws {
        guard !text.isEmpty, !candidates.isEmpty, candidates.allSatisfy({ !$0.isEmpty }),
            Set(candidates).count == candidates.count
        else { throw CapabilityError.invalidRequest("Judge candidates must be nonempty and unique") }
        self.text = text
        self.candidates = candidates
        self.context = context
    }
}

/// A score is a provider estimate, not a calibrated probability. No routing or action is executed here.
public enum JudgeDecision: Equatable, Sendable {
    case selected(label: String, score: Double?)
    case abstained
}

public struct JudgeResult: Equatable, Sendable {
    public let decision: JudgeDecision
    public init(decision: JudgeDecision, for request: JudgeRequest) throws {
        if case .selected(let label, let score) = decision {
            guard request.candidates.contains(label), score.map({ $0.isFinite && (0...1).contains($0) }) ?? true
            else { throw CapabilityError.invalidRequest("Judge result is outside the candidate or score range") }
        }
        self.decision = decision
    }
}

public protocol JudgeCapability: Capability {
    func judge(_ request: JudgeRequest) async throws -> InferenceSession<JudgeResult>
}
