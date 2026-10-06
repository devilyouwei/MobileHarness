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
        guard let domain = values["domain"], let module = values["module"] else { throw MacroError.missingMetadata }
        let metadata = """
            path: ActionIdentifier(domain: \(domain), module: \(module), function: "\(name)"),
            displayName: \(values["title"] ?? "\"\(name)\""),
            kind: \(values["kind"] ?? ".finite"), completion: \(values["completion"] ?? "\"Complete after joined execution.\""),
            serializationKey: \(values["serializationKey"] ?? "nil"),
            resources: \(values["resources"] ?? "[]"), timeout: \(values["timeout"] ?? "nil"),
            resolvingResources: \(values["resolvingResources"] ?? "nil"), estimatingDuration: \(values["estimatingDuration"] ?? "nil")
            """
        return [
            DeclSyntax(
                stringLiteral: """
                    public static func \(name)Definition(handler: @escaping ActionHandler) -> ActionFunction {
                        ActionFunction(\(metadata), handler: handler)
                    }
                    """),
            DeclSyntax(
                stringLiteral: """
                    public static func \(name)Definition(completing handler: @escaping ActionCompletionHandler) -> ActionFunction {
                        ActionFunction(\(metadata), completing: handler)
                    }
                    """),
        ]
    }
    enum MacroError: Error, CustomStringConvertible {
        case staticFunctionRequired, missingMetadata
        var description: String {
            switch self {
            case .staticFunctionRequired: "@Action requires a static function."
            case .missingMetadata: "Missing required behavior metadata."
            }
        }
    }
}
@main struct BehaviorDefinitionPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [BehaviorDefinitionMacro.self]
}
