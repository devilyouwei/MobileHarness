import Foundation
import ModelKit
import ModelKitDefaults
import Testing

/// Opt-in real artifact acceptance. No downloads or substitute model are performed by this test.
@Test(.enabled(if: ProcessInfo.processInfo.environment["D3_TEST_RESOURCES"] != nil))
@MainActor func d3NativeDecisionMatchesPublishedFixtureAndTruncatesOversizedInput() async throws {
    guard #available(macOS 27, iOS 27, *) else {
        throw CapabilityError.unavailable("This native integration test requires macOS 27, iOS 27")
    }
    let path = try #require(ProcessInfo.processInfo.environment["D3_TEST_RESOURCES"])
    let root = ModelContainer(resources: URL(fileURLWithPath: path))
    try await root.start()
    try await root.setForeground(true)
    let decision = root.language.decision
    let request = try DecisionRequest(
        text: "The customer was charged twice for a single order.",
        candidates: [
            "billing: Payments and invoices", "shipping: Delivery and tracking", "account: Login and passwords",
        ],
        instructions: "Which team should handle this?")
    let session = try await decision.choice(request)
    var values: [DecisionResult] = []
    for try await result in session.events { values.append(result) }
    await session.waitForCompletion()
    let first = try #require(values.first)
    guard case .selected(let label, let score) = first.decision else {
        Issue.record("Native D3 did not select a candidate")
        try await root.stop()
        return
    }
    #expect(values.count == 1 && label == request.candidates[0])
    #expect(abs((score ?? 0) - 0.9967046991738012) < 0.03)
    let start = ContinuousClock.now
    let warm = try await decision.choice(request)
    for try await _ in warm.events {}
    await warm.waitForCompletion()
    print("D3 native warm duration: \(start.duration(to: .now))")
    let oversized = try DecisionRequest(text: String(repeating: "hello ", count: 1000), candidates: ["keep", "drop"])
    let longSession = try await decision.choice(oversized)
    let longValues = try await longSession.withCleanup {
        var values: [DecisionResult] = []
        for try await result in longSession.events { values.append(result) }
        return values
    }
    #expect(longValues.count == 1)
    try await root.stop()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["D3_EDGE_TEST_RESOURCES"] != nil))
@MainActor func d3NativeDecisionRunsTextGraphAndTruncatesOversizedInput() async throws {
    guard #available(macOS 27, iOS 27, *) else {
        throw CapabilityError.unavailable("This native integration test requires macOS 27, iOS 27")
    }
    let path = try #require(ProcessInfo.processInfo.environment["D3_EDGE_TEST_RESOURCES"])
    let modelID = ProcessInfo.processInfo.environment["D3_NATIVE_MODEL_ID"] ?? "d3-edge"
    let root = ModelContainer(resources: URL(fileURLWithPath: path))
    try await root.start()
    do {
        try await root.setForeground(true)
        let model = try #require(root.language.decisionModel(modelID))
        #expect(await model.availability == .available)
        let started = ContinuousClock.now
        try await model.warmup()
        print("\(modelID) native warmup duration: \(started.duration(to: .now))")
        #expect(try await model.status() == .ready)
        let request = try DecisionRequest(
            text: "The customer was charged twice for a single order.",
            candidates: [
                "billing: Payments and invoices", "shipping: Delivery", "account: Login", "wishlist: Saved items",
            ],
            instructions: "Which team should handle this?")
        let session = try await model.choice(request)
        let values = try await session.withCleanup {
            var values: [DecisionResult] = []
            for try await result in session.events { values.append(result) }
            return values
        }
        try #require(values.count == 1)
        guard case .selected(let label, let score) = values[0].decision else {
            throw CapabilityError.invalidRequest("D3 did not select a candidate")
        }
        #expect(label == request.candidates[0])
        #expect(score?.isFinite == true)
        let oversized = try DecisionRequest(
            text: String(repeating: "hello ", count: 1000), candidates: ["keep", "drop"])
        let longSession = try await model.choice(oversized)
        let longValues = try await longSession.withCleanup {
            var values: [DecisionResult] = []
            for try await result in longSession.events { values.append(result) }
            return values
        }
        #expect(longValues.count == 1)
    } catch {
        try await root.stop()
        throw error
    }
    try await root.stop()
}
