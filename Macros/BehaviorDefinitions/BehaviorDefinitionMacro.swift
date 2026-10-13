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
            declaration: \(name)Declaration,
            displayName: \(values["title"] ?? "\"\(name)\""),
            kind: \(values["kind"] ?? ".finite"), completion: \(values["completion"] ?? "\"Complete after joined execution.\""),
            resources: \(values["resources"] ?? "[]"), timeout: \(values["timeout"] ?? "nil"),
            resolvingResources: \(values["resolvingResources"] ?? "nil"), dynamicTimeout: \(values["dynamicTimeout"] ?? "nil")
            """
        return [
            DeclSyntax(
                stringLiteral: """
                    public static var \(name)Declaration: ActionDeclaration {
                        ActionDeclaration(path: ActionIdentifier(domain: \(domain), module: \(module), function: "\(name)"),
                            doc: \(values["doc"] ?? values["title"] ?? "\"\(name)\""), parameters: \(values["parameters"] ?? "[]"))
                    }
                    """),
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
    let providingMacros: [Macro.Type] = [BehaviorDefinitionMacro.self, ActionCatalogMacro.self]
}

/// Inspect the module's actual factory calls, including local helper arrays.
public struct ActionCatalogMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let collector = FactoryCollector(viewMode: .sourceAccurate)
        collector.walk(Syntax(declaration.memberBlock))
        let members = collector.names.sorted().map { $0 + "Declaration" }.joined(separator: ",\n")
        return [DeclSyntax(stringLiteral: "public static var declarations: [ActionDeclaration] { [\(members)] }")]
    }
    private final class FactoryCollector: SyntaxVisitor {
        var names = Set<String>()
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
                member.declName.baseName.text.hasSuffix("Definition"), let base = member.base
            {
                let name = member.declName.baseName.text.dropLast("Definition".count)
                names.insert(base.trimmedDescription + "." + name)
            }
            return .visitChildren
        }
    }
}
