import Actions
import Testing

@testable import Agents

struct ActionCatalogFixture: TestTrait, TestScoping {
    private static let installation = Result {
        try AgentConfigurations.installDeclarations(CapabilityModules.declarations)
    }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void)
        async throws
    {
        try Self.installation.get()
        try await function()
    }
}
extension Trait where Self == ActionCatalogFixture {
    static var actionCatalog: Self { Self() }
}

@Suite(.serialized) struct LiveRuntimeTests {}
