import Foundation

public struct DecisionRequest: Sendable {
    public let context: InferenceContext
    public let text: String
    public let candidates: [String]
    public let instructions: String
    public init(
        text: String, candidates: [String], context: InferenceContext = InferenceContext(),
        instructions: String = "Choose the best matching option."
    ) throws {
        guard !text.isEmpty, text.utf8.count <= 20_480, !candidates.isEmpty, candidates.count <= 255,
            instructions.utf8.count <= 4096, candidates.allSatisfy({ !$0.isEmpty }),
            Set(candidates).count == candidates.count
        else { throw CapabilityError.invalidRequest("Decision candidates must be nonempty and unique") }
        self.instructions = instructions
        self.text = text
        self.candidates = candidates
        self.context = context
    }
}

/// A score is a provider estimate, not a calibrated probability. No routing or action is executed here.
public enum DecisionSelection: Equatable, Sendable {
    case selected(label: String, score: Double?)
    case abstained
}

public struct DecisionResult: Equatable, Sendable {
    public let decision: DecisionSelection
    public init(decision: DecisionSelection, for request: DecisionRequest) throws {
        if case .selected(let label, let score) = decision {
            guard request.candidates.contains(label), score.map({ $0.isFinite && (0...1).contains($0) }) ?? true
            else { throw CapabilityError.invalidRequest("Decision result is outside the candidate or score range") }
        }
        self.decision = decision
    }
}

public protocol DecisionCapability: Capability {
    func decide(_ request: DecisionRequest) async throws -> InferenceSession<DecisionResult>
}
