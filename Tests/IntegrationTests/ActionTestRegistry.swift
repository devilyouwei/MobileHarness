import Actions
import AgentCore

/// Explicit implementation metadata for generic scheduler fixtures, not production registration.
func testActionRegistry(handlers: [ActionPath: ActionHandler]) throws -> ActionRegistry {
    try ActionRegistry(
        definitions: handlers.map { path, handler in
            ActionDefinition(
                path: path, kind: .finite, completion: "Fixture acknowledgment completed.", handler: handler)
        })
}
