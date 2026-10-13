import Actions
import Agents
import Testing

struct ActionCatalogFixture: TestTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void)
        async throws
    {
        try AgentConfigurations.installDeclarations(CapabilityModules.declarations)
        try await function()
    }
}
extension Trait where Self == ActionCatalogFixture {
    static var actionCatalog: Self { Self() }
}
