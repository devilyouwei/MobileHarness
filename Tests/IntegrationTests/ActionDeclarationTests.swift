import Actions
import Agents
import Foundation
import FunctionContracts
import StorageChat
import StorageCore
import Testing

@Test(.actionCatalog) func actionMacroOwnsSchemasAndModuleProjection() throws {
    let declarations = CapabilityModules.declarations
    #expect(Set(declarations.map(\.path)).count == declarations.count)
    #expect(declarations.contains(CameraActions.takePhotoDeclaration))
    #expect(declarations.contains(SystemActions.startTaskDeclaration))
    let function = CameraActions.takePhotoDefinition(handler: { _ in })
    #expect(function.declaration == CameraActions.takePhotoDeclaration)
    try function.validate()
    #expect(CameraActions.savePhotoDeclaration.parameters.map(\.name) == ["mediaID"])
    let object = try CameraActions.savePhotoDeclaration.actionObject(alias: "save")
    #expect(object["examples"] == nil)
    #expect(object["alias"] as? String == "save")
    #expect((object["parameters"] as? [[String: Any]])?.first?["required"] as? Bool == true)
    for registry in try AgentConfigurations.skillRegistries() {
        for tool in registry.tools {
            let declaration = try #require(declarations.first { $0.path.description == tool.path })
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
    let store = ConversationHistoryStore()
    let id = UUID().uuidString
    let prompt = String(repeating: "x", count: 65_536)
    let token = try await store.readCurrent().token
    let record = try await store.begin(
        id: id, user: "task", request: [.init(role: .system, content: prompt)], expecting: token, model: "fixture")
    #expect(record.request.first?.content == prompt)
    try await store.finish(id, state: .completed, reason: "stop")
    await #expect(throws: ConversationHistoryError.invalidRecord) {
        let token = try await store.readCurrent().token
        _ = try await store.begin(
            id: UUID().uuidString, user: "task", request: [.init(role: .system, content: prompt + "x")],
            expecting: token,
            model: "fixture")
    }
}
