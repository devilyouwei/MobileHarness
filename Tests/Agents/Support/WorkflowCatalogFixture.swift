import Actions
import Testing

@testable import Agents

struct WorkflowCatalogFixture: TestTrait, TestScoping {
    private static let installation = Result {
        try AgentConfigurations.installDeclarations(
            CapabilityModules.declarations, localTools: AgentContracts.localTools)
    }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void)
        async throws
    {
        try Self.installation.get()
        try await function()
    }
}
extension Trait where Self == WorkflowCatalogFixture {
    static var actionCatalog: Self { Self() }
}
