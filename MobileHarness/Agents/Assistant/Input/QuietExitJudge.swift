import Foundation
import ModelKit

public struct QuietJudgement: Sendable, Equatable {
    public enum Decision: Sendable, Equatable { case stay, exit }
    public let decision: Decision
    public let tier: String
    public let modelID: String?
    public let latencyMS: Int
}

/// Builds the quiet question. The shared Decision service owns model selection and inference.
public struct QuietExitJudge: Sendable {
    public static let maximumSentenceCharacters = 512
    static let literalPrefix = "literal:"
    private let decision: AssistantInputDecision

    public init(decision: AssistantInputDecision) { self.decision = decision }

    public func judge(
        _ sentence: String, wakeCondition: String? = nil, context: InferenceContext
    ) async throws -> QuietJudgement {
        let started = ContinuousClock.now
        try Task.checkCancellation()
        let utterance = String(
            sentence.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumSentenceCharacters))
        let condition = wakeCondition.map { value in
            guard value.hasPrefix(Self.literalPrefix) else { return value }
            return "The user must say this exact phrase: " + value.dropFirst(Self.literalPrefix.count)
        }
        let outcome = await decision.classify(receivedAt: started) {
            let text: String
            if let condition {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                text = String(
                    decoding: try encoder.encode(["latestUtterance": utterance, "wakeCondition": condition]),
                    as: UTF8.self)
            } else {
                text = utterance
            }
            let instructions = try AgentPrompts.text(
                "Assistant/Input/QuietExit", condition == nil ? "instructions" : "conditioned")
            return try NoulRequest(text: text, instructions: instructions, context: context)
        }
        try Task.checkCancellation()
        let tier: String
        let selectedLocalID: String?
        switch outcome.route {
        case .local(let id):
            tier = "local"
            selectedLocalID = id
        case .cloud:
            tier = "cloud"
            selectedLocalID = nil
        case .superseded:
            throw CancellationError()
        case .failed:
            throw CapabilityError.unavailable(outcome.reason ?? "Quiet exit Decision failed")
        }
        guard let awake = outcome.modelResult else {
            throw CapabilityError.invalidRequest("Quiet exit Decision returned no result")
        }
        let elapsed = started.duration(to: .now).components
        return .init(
            decision: awake ? .exit : .stay, tier: tier,
            modelID: outcome.inference?.model?.modelID ?? selectedLocalID,
            latencyMS: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000))
    }
}
