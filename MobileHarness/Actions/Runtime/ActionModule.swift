/// A module owns implementation definitions, never Agent permissions or device construction.
public protocol ActionModule: Sendable {
    var definitions: [ActionDefinition] { get }
}
