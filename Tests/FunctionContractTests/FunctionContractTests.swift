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
    let context = ActionExecutionContext(source: "fixture", sessionID: UUID(), inputID: UUID(), sequence: 3)
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
        call: FunctionRequest(actionPath: path, parameters: ["id": "one"]), context: context, results: sink)
    #expect(try await function.handler(input) == .value("one"))
    #expect(await sink.snapshot() == report)
    #expect(try function.requiredResources(for: input.call) == [.init(rawValue: "fixture.journal")])
}
