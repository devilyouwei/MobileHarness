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
    func decide(_ request: MultiDecisionRequest) async throws -> InferenceSession<MultiDecisionResult>
    func choice(_ request: DecisionRequest) async throws -> InferenceSession<DecisionResult>
    func noul(_ request: NoulRequest) async throws -> InferenceSession<NoulResult>
}

public struct NoulRequest: Sendable {
    public let text: String
    public let instructions: String
    public let context: InferenceContext
    public init(text: String, instructions: String, context: InferenceContext = InferenceContext()) throws {
        _ = try DecisionRequest(
            text: text, candidates: ["false", "true"], context: context, instructions: instructions)
        self.text = text
        self.instructions = instructions
        self.context = context
    }
}

/// score is the model estimate for true, not calibrated confidence.
public struct NoulResult: Sendable, Equatable {
    public let value: Bool
    public let score: Double?
    public init(value: Bool, score: Double? = nil) throws {
        guard score.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
            throw CapabilityError.invalidRequest("Invalid boolean decision score")
        }
        self.value = value
        self.score = score
    }
}

extension DecisionCapability {
    /// D3's official native noul criteria, in false/true order.
    public func noul(_ request: NoulRequest) async throws -> InferenceSession<NoulResult> {
        try await booleanReadout(request, candidates: ["No / false", "Yes / true"])
    }

    public func booleanReadout(_ request: NoulRequest, candidates: [String]) async throws -> InferenceSession<
        NoulResult
    > {
        guard candidates.count == 2 else { throw CapabilityError.invalidRequest("Boolean readout needs two options") }
        let choiceRequest = try DecisionRequest(
            text: request.text, candidates: candidates,
            context: request.context, instructions: request.instructions)
        let source = try await choice(choiceRequest)
        let control = InferenceTaskControl()
        let pair = InferenceSession<NoulResult>.make(
            context: request.context,
            limits: try StreamLimits(capacity: 1), estimatedBytes: { _ in 32 },
            onTermination: { reason in
                if case .finished = reason { return }
                source.cancel()
                control.cancel()
            }, waitForCompletion: { await control.waitForCompletion() })
        let task = Task {
            do {
                let result = try await source.withCleanup {
                    var result: NoulResult?
                    for try await item in source.events {
                        guard result == nil, case .selected(let label, let score) = item.decision,
                            let index = candidates.firstIndex(of: label)
                        else {
                            throw CapabilityError.invalidRequest("Invalid boolean readout")
                        }
                        let pTrue = score.map { index == 1 ? $0 : 1 - $0 }
                        result = try NoulResult(value: index == 1, score: pTrue)
                    }
                    guard let result else { throw CapabilityError.invalidRequest("Missing boolean readout") }
                    return result
                }
                try pair.emitter.yield(result)
                pair.emitter.finish()
            } catch { pair.emitter.fail(error) }
            control.finish()
        }
        try control.install(task)
        return pair.session
    }
}

/// Questions share text and context; their order determines execution order.
public struct DecisionQuestion: Sendable {
    public enum Kind: Sendable {
        case choice(instructions: String, candidates: [String])
        case noul(instructions: String)
    }
    public let id: String
    public let kind: Kind
    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public struct MultiDecisionRequest: Sendable {
    public let text: String
    public let context: InferenceContext
    public let questions: [DecisionQuestion]
    public init(
        text: String, questions: [DecisionQuestion], context: InferenceContext = InferenceContext()
    ) throws {
        guard (1...32).contains(questions.count), questions.allSatisfy({ !$0.id.isEmpty }),
            Set(questions.map(\.id)).count == questions.count
        else { throw CapabilityError.invalidRequest("Decision requires 1–32 questions with unique nonempty IDs") }
        for question in questions {
            switch question.kind {
            case .choice(let instructions, let candidates):
                _ = try DecisionRequest(
                    text: text, candidates: candidates, context: context, instructions: instructions)
            case .noul(let instructions):
                _ = try NoulRequest(text: text, instructions: instructions, context: context)
            }
        }
        self.text = text
        self.questions = questions
        self.context = context
    }
}

public enum DecisionAnswer: Sendable, Equatable {
    case choice(DecisionResult)
    case noul(NoulResult)
}

public struct MultiDecisionResult: Sendable, Equatable {
    public let answers: [String: DecisionAnswer]
    public init(answers: [String: DecisionAnswer]) { self.answers = answers }
}

extension DecisionCapability {
    /// Serial independent inference, using each provider's choice and noul implementations.
    public func decide(_ request: MultiDecisionRequest) async throws -> InferenceSession<MultiDecisionResult> {
        let control = InferenceTaskControl()
        let pair = InferenceSession<MultiDecisionResult>.make(
            context: request.context,
            limits: try StreamLimits(capacity: 1, maximumEventBytes: nil),
            estimatedBytes: { result in
                result.answers.reduce(0) { size, entry in
                    let labelBytes: Int
                    if case .choice(let result) = entry.value,
                        case .selected(let label, _) = result.decision
                    {
                        labelBytes = label.utf8.count
                    } else {
                        labelBytes = 0
                    }
                    return size + entry.key.utf8.count + labelBytes + 32
                }
            },
            onTermination: { reason in
                if case .finished = reason { return }
                control.cancel()
            }, waitForCompletion: { await control.waitForCompletion() })
        let task = Task {
            do {
                var answers: [String: DecisionAnswer] = [:]
                for question in request.questions {
                    try Task.checkCancellation()
                    switch question.kind {
                    case .choice(let instructions, let candidates):
                        let source = try await choice(
                            DecisionRequest(
                                text: request.text, candidates: candidates, context: request.context,
                                instructions: instructions))
                        answers[question.id] = .choice(try await singleDecisionResult(source))
                    case .noul(let instructions):
                        let source = try await noul(
                            NoulRequest(
                                text: request.text, instructions: instructions, context: request.context))
                        answers[question.id] = .noul(try await singleDecisionResult(source))
                    }
                }
                try Task.checkCancellation()
                try pair.emitter.yield(MultiDecisionResult(answers: answers))
                pair.emitter.finish()
            } catch { pair.emitter.fail(error) }
            control.finish()
        }
        try control.install(task)
        return pair.session
    }
}

private func singleDecisionResult<Result: Sendable>(_ source: InferenceSession<Result>) async throws -> Result {
    try await source.withCleanup {
        var result: Result?
        for try await item in source.events {
            guard result == nil else {
                throw CapabilityError.invalidRequest("Multiple results for one decision question")
            }
            result = item
        }
        guard let result else { throw CapabilityError.invalidRequest("Missing decision question result") }
        return result
    }
}
