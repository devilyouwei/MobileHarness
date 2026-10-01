import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Generate explicit metadata factories; permissions and host bindings remain outside the macro.
public struct BehaviorDefinitionMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self),
            function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }),
            case .argumentList(let arguments) = node.arguments
        else { throw MacroError.staticFunctionRequired }
        let values = Dictionary(
            uniqueKeysWithValues: arguments.compactMap { argument in
                argument.label.map { ($0.text, argument.expression.trimmedDescription) }
            })
        let name = function.name.text
        let isAction = node.attributeName.trimmedDescription == "Action"
        let title = values["title"] ?? "\"\(name)\""
        if isAction {
            guard let module = values["module"], let kind = values["kind"], let completion = values["completion"] else {
                throw MacroError.missingMetadata
            }
            let metadata = """
                path: ActionPath(module: \(module), function: "\(name)"), displayName: \(title),
                kind: \(kind), completion: \(completion),
                resolvingResources: \(values["resources"] ?? "nil"),
                estimatingDuration: \(values["timeout"] ?? "nil")
                """
            return [
                DeclSyntax(
                    stringLiteral: """
                        public static func \(name)Definition(handler: @escaping ActionHandler) -> ActionDefinition {
                            ActionDefinition(\(metadata), handler: handler)
                        }
                        """),
                DeclSyntax(
                    stringLiteral: """
                        public static func \(name)Definition(completing handler: @escaping ActionCompletionHandler) -> ActionDefinition {
                            ActionDefinition(\(metadata), completing: handler)
                        }
                        """),
            ]
        }
        guard let path = values["path"] else { throw MacroError.missingMetadata }
        return [
            DeclSyntax(
                stringLiteral: """
                    public static func \(name)Definition(handler: @escaping ToolRegistry.Handler) -> ToolDefinition {
                        ToolDefinition(path: \(path), displayName: \(title), resources: \(values["resources"] ?? "[]"), handler: handler)
                    }
                    """),
            DeclSyntax(
                stringLiteral: """
                    public static func \(name)Definition(completing handler: @escaping ToolRegistry.CompletionHandler) -> ToolDefinition {
                        ToolDefinition(path: \(path), displayName: \(title), resources: \(values["resources"] ?? "[]"), completing: handler)
                    }
                    """),
        ]
    }
    enum MacroError: Error, CustomStringConvertible {
        case staticFunctionRequired, missingMetadata
        var description: String {
            switch self {
            case .staticFunctionRequired: "@Action/@Tool requires a static function."
            case .missingMetadata: "Missing required behavior metadata."
            }
        }
    }
}
@main struct BehaviorDefinitionPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [BehaviorDefinitionMacro.self]
}
