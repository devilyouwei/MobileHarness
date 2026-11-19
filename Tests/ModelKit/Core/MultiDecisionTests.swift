import ModelKit
import Testing

private actor MultiDecisionFixture: DecisionCapability {
    let availability: CapabilityAvailability = .available
    var calls: [String] = []
    var contexts: [InferenceContext] = []
    var texts: [String] = []
    var cleaned = false
    let failure: Bool
    let suspend: Bool
    init(failure: Bool = false, suspend: Bool = false) {
        self.failure = failure
        self.suspend = suspend
    }
    func choice(_ request: DecisionRequest) async throws -> InferenceSession<DecisionResult> {
        calls.append(request.instructions)
        contexts.append(request.context)
        texts.append(request.text)
        if failure { throw CapabilityError.unavailable("fixture failure") }
        let pair = InferenceSession<DecisionResult>.make(
            context: request.context, limits: try StreamLimits(capacity: 1), estimatedBytes: { _ in 32 },
            waitForCompletion: { await self.markCleaned() })
        if !suspend {
            try pair.emitter.yield(
                DecisionResult(decision: .selected(label: request.candidates[0], score: nil), for: request))
            pair.emitter.finish()
        }
        return pair.session
    }
    func noul(_ request: NoulRequest) async throws -> InferenceSession<NoulResult> {
        calls.append(request.instructions)
        contexts.append(request.context)
        texts.append(request.text)
        let pair = InferenceSession<NoulResult>.make(
            limits: try StreamLimits(capacity: 1), estimatedBytes: { _ in 32 })
        try pair.emitter.yield(NoulResult(value: true, score: 0.8))
        pair.emitter.finish()
        return pair.session
    }
    func markCleaned() { cleaned = true }
}

private func multiRequest() throws -> MultiDecisionRequest {
    try MultiDecisionRequest(
        text: "shared text",
        questions: [
            DecisionQuestion(id: "category", kind: .choice(instructions: "first", candidates: ["A", "B"])),
            DecisionQuestion(id: "flag", kind: .noul(instructions: "second")),
        ])
}

@Test func multiDecisionPreservesTypesOrderAndSharedContext() async throws {
    let provider = MultiDecisionFixture()
    let request = try multiRequest()
    let session = try await provider.decide(request)
    let results = try await session.withCleanup {
        var results: [MultiDecisionResult] = []
        for try await result in session.events { results.append(result) }
        return results
    }
    #expect(results.count == 1)
    #expect(results.first?.answers["flag"] == .noul(try NoulResult(value: true, score: 0.8)))
    if case .choice(let result) = results.first?.answers["category"] {
        #expect(result.decision == .selected(label: "A", score: nil))
    } else {
        Issue.record("Missing choice result")
    }
    #expect(await provider.calls == ["first", "second"])
    #expect(await provider.texts == [request.text, request.text])
    #expect(await provider.contexts == [request.context, request.context])
    #expect(await provider.cleaned)
}

@Test func multiDecisionFailureStopsRemainingQuestions() async throws {
    let provider = MultiDecisionFixture(failure: true)
    let session = try await provider.decide(multiRequest())
    await #expect(throws: CapabilityError.unavailable("fixture failure")) {
        try await session.withCleanup {
            for try await _ in session.events { Issue.record("Unexpected aggregate") }
        }
    }
    #expect(await provider.calls == ["first"])
}

@Test func multiDecisionCancellationJoinsActiveQuestion() async throws {
    let provider = MultiDecisionFixture(suspend: true)
    let session = try await provider.decide(multiRequest())
    while await provider.calls.isEmpty { await Task.yield() }
    session.cancel()
    await session.waitForCompletion()
    #expect(await provider.calls == ["first"])
    #expect(await provider.cleaned)
}

@Test func multiDecisionRejectsDuplicateQuestionIDs() throws {
    #expect(throws: CapabilityError.self) {
        try MultiDecisionRequest(
            text: "text",
            questions: [
                DecisionQuestion(id: "same", kind: .noul(instructions: "one")),
                DecisionQuestion(id: "same", kind: .noul(instructions: "two")),
            ])
    }
}
