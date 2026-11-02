import ExecutionRuntime
import Foundation
import FunctionContracts

/// One admitted capture: reuse the canonical open action, then return only the actual capture result.
enum CameraCaptureWorkflow {
    static func run<Value: Sendable>(
        invocation: any FunctionInput, camera: any CameraControlCapability,
        capture: String, timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let open = CameraActions.openDefinition(completing: {
            .value(try await CameraActions.open(invocation: $0, using: camera))
        })
        let child = FunctionInvocation(
            call: .init(actionPath: open.path, parameters: [:]), context: invocation.context,
            executionID: UUID().uuidString, results: ActionReportStore())
        let preparation = try ActionComposition(.action(function: open, invocation: child))
        return try await preparation.run(
            returning: capture, budget: .init(expected: .zero, timeout: timeout),
            results: invocation.results, operation: operation)
    }
}
