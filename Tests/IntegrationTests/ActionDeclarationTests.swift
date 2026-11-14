import Actions
import AgentCore
import Foundation
import FunctionContracts
import StorageChat
import StorageCore
import Testing

@testable import Agents

@Test(.actionCatalog) func actionMacroOwnsSchemasAndModuleProjection() throws {
    let declarations = CapabilityModules.declarations
    #expect(Set(declarations.map(\.path)).count == declarations.count)
    #expect(declarations.contains(CameraActions.takePhotoDeclaration))
    #expect(declarations.contains(SystemActions.startTaskDeclaration))
    let function = CameraActions.takePhotoDefinition(handler: { _ in })
    #expect(function.declaration == CameraActions.takePhotoDeclaration)
    try function.validate()
    #expect(CameraActions.savePhotoDeclaration.parameters.map(\.name) == ["previewID"])
    let object = try CameraActions.savePhotoDeclaration.actionObject(alias: "save")
    #expect(object["examples"] == nil)
    #expect(object["alias"] as? String == "save")
    #expect((object["parameters"] as? [[String: Any]])?.first?["required"] as? Bool == true)
    let toolDeclarations = declarations + WriterLocalTools.declarations
    #expect(Set(toolDeclarations.map(\.path)).count == toolDeclarations.count)
    for registry in try AgentConfigurations.skillRegistries() {
        for tool in registry.tools {
            let declaration = try #require(toolDeclarations.first { $0.path.description == tool.path })
            #expect(tool.requiredParameters == Set(declaration.parameters.filter(\.required).map(\.name)))
        }
    }
}

@Test(.actionCatalog) func immutableActionCatalogRejectsMissingDuplicateAndReplacementDeclarations() throws {
    #expect(throws: (any Error).self) { try AgentConfigurations.installDeclarations([]) }
    #expect(throws: (any Error).self) {
        try AgentConfigurations.installDeclarations([
            CameraActions.takePhotoDeclaration, CameraActions.takePhotoDeclaration,
        ])
    }
    #expect(throws: (any Error).self) {
        try AgentConfigurations.installDeclarations([CameraActions.takePhotoDeclaration])
    }
    let binding = try JSONDecoder().decode(
        AgentConfigurations.Binding.self,
        from: Data(
            #"{"path":"Missing.Camera.capture","callType":"action","alias":"capture","channel":"Camera"}"#.utf8))
    #expect(throws: (any Error).self) { try AgentConfigurations.registry([binding]) }
    let invalid = ActionDeclaration(path: .init(domain: "Camera", module: "Capture", function: "broken"), doc: "")
    #expect(throws: (any Error).self) { try invalid.validate() }
}

@Test(.actionCatalog) func skillPromptHistoryAccepts64KiBAndRejectsLargerEvidence() async throws {
    let store = AssistantHistoryStore()
    let id = UUID().uuidString
    let prompt = String(repeating: "x", count: 65_536)
    let token = try await store.readCurrent().token
    let record = try await store.begin(
        id: id, user: "task", request: [.init(role: .system, content: prompt)], expecting: token, model: "fixture")
    #expect(record.request.first?.content == prompt)
    try await store.finish(id, state: .completed, reason: "stop")
    await #expect(throws: AssistantHistoryError.invalidRecord) {
        let token = try await store.readCurrent().token
        _ = try await store.begin(
            id: UUID().uuidString, user: "task", request: [.init(role: .system, content: prompt + "x")],
            expecting: token,
            model: "fixture")
    }
}

@Test(.actionCatalog) func localToolProjectionRequiresItsDeclaredOwnerAndNativeProtocol() throws {
    let binding = AgentConfigurations.Binding(
        path: "Agent.Writer.ask", callType: "tool", alias: "ask", channel: nil)
    let registry = try AgentConfigurations.registry([binding], owner: .writer)
    #expect(registry.tools.map(\.path) == ["Agent.Writer.ask"])
    #expect(registry.tools.first?.requiredParameters == ["question"])
    #expect(throws: AgentConfigurationError.self) { try AgentConfigurations.registry([binding]) }
    #expect(throws: AgentConfigurationError.self) {
        try AgentConfigurations.registry([binding], owner: .assistant)
    }
    let action = AgentConfigurations.Binding(
        path: binding.path, callType: "action", alias: "ask", channel: "Control")
    #expect(throws: AgentConfigurationError.self) { try AgentConfigurations.registry([action], owner: .writer) }
}

@Test func injectedLocalCatalogRejectsDuplicateAndConflictingImplementations() throws {
    let external = ActionDeclaration(path: .init(domain: "Fixture", module: "External", function: "read"), doc: "Read.")
    let local = AgentLocalTool(
        owner: .init(rawValue: "fixtureRole"),
        declaration: .init(path: .init(domain: "Fixture", module: "Local", function: "ask"), doc: "Ask."))
    let catalog = try AgentFunctionCatalog(declarations: [external], localTools: [local])
    #expect(
        try catalog.declaration(path: local.declaration.path.description, callType: "tool", owner: local.owner)
            == local.declaration)
    #expect(throws: AgentConfigurationError.self) {
        try catalog.declaration(path: local.declaration.path.description, callType: "tool", owner: .assistant)
    }
    #expect(throws: AgentConfigurationError.self) {
        try AgentFunctionCatalog(declarations: [external], localTools: [local, local])
    }
    #expect(throws: AgentConfigurationError.self) {
        try AgentFunctionCatalog(declarations: [local.declaration], localTools: [local])
    }
    #expect(throws: AgentConfigurationError.self) {
        try AgentFunctionCatalog(
            declarations: [external], localTools: [.init(owner: .init(rawValue: ""), declaration: local.declaration)])
    }
}

@Test(.actionCatalog) func localCatalogInstallationIsImmutableAndOrderIndependent() throws {
    let before = try AgentConfigurations.load(named: "Writer").capabilities.tools.map(\.path)
    try AgentConfigurations.installDeclarations(
        CapabilityModules.declarations.reversed(), localTools: AgentContracts.localTools.reversed())
    #expect(try AgentConfigurations.load(named: "Writer").capabilities.tools.map(\.path) == before)
    #expect(throws: AgentConfigurationError.self) {
        try AgentConfigurations.installDeclarations(CapabilityModules.declarations)
    }
    let changed = AgentContracts.localTools.map { AgentLocalTool(owner: .assistant, declaration: $0.declaration) }
    #expect(throws: AgentConfigurationError.self) {
        try AgentConfigurations.installDeclarations(CapabilityModules.declarations, localTools: changed)
    }
}

@Test func capabilityCoverageRequiresExplicitExactLocalToolPaths() throws {
    let path = "Fixture.Local.ask"
    let capabilities = try CapabilityRegistry(internalTools: [.init(path: path, required: ["question"])])
    let catalog = ActionCatalogSnapshot(revision: UUID(), entries: [])
    #expect(throws: HarnessError.forbiddenTool) {
        try CapabilityCoverage.validate(catalog: catalog, capabilities: [capabilities])
    }
    #expect(throws: HarnessError.forbiddenTool) {
        try CapabilityCoverage.validate(
            catalog: catalog, capabilities: [capabilities], locallyExecutedTools: ["Fixture.Local"])
    }
    try CapabilityCoverage.validate(catalog: catalog, capabilities: [capabilities], locallyExecutedTools: [path])
    #expect(!capabilities.permits(ToolCall(id: "model", toolPath: path)))
}
