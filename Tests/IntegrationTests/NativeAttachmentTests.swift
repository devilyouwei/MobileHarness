import CallRuntime
import Foundation
import FunctionContracts
import Testing

private struct NativeFixtureModule: CapabilityModule {
    let definitions: [ActionFunction]
}
private final class NativeFixturePayload: Sendable { let value = 42 }

@Test func nativeToolExecutionReceivesOnlyExplicitInProcessAttachments() async throws {
    let path = ActionIdentifier(domain: "Fixture", module: "Media", function: "present")
    let definition = ActionFunction(
        path: path, displayName: "Native fixture", kind: .finite,
        completion: "Accepted",
        completing: { input in
            guard let native = input.attachment as? NativeFixturePayload else { return .value("missing") }
            return .value(String(native.value))
        })
    let registry = try ToolRegistry(modules: [NativeFixtureModule(definitions: [definition])] as [any CapabilityModule])
    let executor = ToolExecutor(registry: registry)
    let context = ActionExecutionContext(source: "fixture", sessionID: "session", inputID: "input")
    let call = ToolRequest(id: "call", toolPath: path.description, arguments: ["attachment": "forged"])
    let missing = try await executor.execute(call, context: context, returning: true)
    #expect(missing?.value == "missing")
    let result = try await executor.execute(call, context: context, returning: true, attachment: NativeFixturePayload())
    #expect(result?.value == "42")
}
