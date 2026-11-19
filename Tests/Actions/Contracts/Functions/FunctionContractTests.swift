import Foundation
import FunctionContracts
import Testing

private actor ContractReportSink: FunctionReporting {
    private var report: ActionReport?
    func record(_ report: ActionReport) throws {
        guard self.report == nil else { throw ActionExecutionError.invalidCompletion }
        self.report = report
    }
    func snapshot() -> ActionReport? { report }
}

@Test func standardFunctionInputRunsWithoutExecutionOrCallProtocolDependencies() async throws {
    let path = ActionIdentifier(domain: "Fixture", module: "Query", function: "read")
    let context = ActionExecutionContext(
        source: "fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString, sequence: 3)
    let sink = ContractReportSink()
    let report = try ActionReport(entries: [.init(path: path.description, status: .succeeded)])
    let function = ActionFunction(
        path: path, displayName: "Read", kind: .finite, completion: "Read acknowledged.",
        resources: [.init(rawValue: "fixture.journal")], timeout: .seconds(2),
        completing: { input in
            #expect(input.context == context)
            try await input.results.record(report)
            return .value(try ActionArguments(input.call.parameters).requiredString("id", maximumUTF8Bytes: 16))
        })
    try function.validate()
    let input = FunctionInvocation(
        call: FunctionRequest(actionPath: path, parameters: ["id": "one"]), context: context,
        executionID: UUID().uuidString, results: sink)
    #expect(try await function.handler(input) == .value("one"))
    #expect(await sink.snapshot() == report)
    #expect(try function.requiredResources(for: input.call) == [.init(rawValue: "fixture.journal")])
}

@Test func intrinsicTimeoutDefaultAndDynamicPrecedenceAreValidated() throws {
    let path = ActionIdentifier(domain: "Fixture", module: "Budget", function: "run")
    let call = FunctionRequest(actionPath: path)
    let fallback = ActionFunction(
        path: path, displayName: "Default", kind: .finite, completion: "Joined", handler: { _ in })
    #expect(fallback.timeout == .seconds(30))
    #expect(try fallback.executionBudget(for: call) == .default)
    let dynamic = ActionFunction(
        path: path, displayName: "Dynamic", kind: .finite, completion: "Joined", timeout: .seconds(1),
        dynamicTimeout: { request in
            try .init(expected: .seconds(2), timeout: .seconds(request.parameters["long"] == "true" ? 60 : 3))
        }, handler: { _ in })
    #expect(try dynamic.executionBudget(for: call).timeout == .seconds(3))
    #expect(
        try dynamic.executionBudget(for: .init(actionPath: path, parameters: ["long": "true"])).timeout == .seconds(60))
    let invalid = ActionFunction(
        path: path, displayName: "Invalid", kind: .finite, completion: "Joined", timeout: .zero,
        dynamicTimeout: { _ in .default }, handler: { _ in })
    #expect(throws: ActionExecutionError.self) { try invalid.executionBudget(for: call) }
    let failing = ActionFunction(
        path: path, displayName: "Failing", kind: .finite, completion: "Joined",
        dynamicTimeout: { _ in throw ActionExecutionBudget.InvalidBudget.outOfRange }, handler: { _ in })
    #expect(throws: ActionExecutionBudget.InvalidBudget.self) { try failing.executionBudget(for: call) }
    #expect(throws: ActionExecutionBudget.InvalidBudget.self) {
        try ActionExecutionBudget.sequence([
            .init(expected: .zero, timeout: .seconds(50_000)),
            .init(expected: .zero, timeout: .seconds(50_000)),
        ])
    }
}
