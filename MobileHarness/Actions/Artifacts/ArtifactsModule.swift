import FunctionContracts

public struct ArtifactsModule: CapabilityModule {
    private let artifacts: any ArtifactCapability
    public init(artifacts: any ArtifactCapability) { self.artifacts = artifacts }
    public static let declarations = ArtifactsActions.workspaceDeclarations
    public var definitions: [ActionFunction] {
        Self.declarations.map { declaration in
            ActionFunction(
                path: declaration.path, declaration: declaration, displayName: declaration.path.function,
                kind: .finite, completion: declaration.doc, timeout: .seconds(60),
                completing: { [artifacts] in
                    .value(try await artifacts.perform(invocation: $0))
                })
        }
    }
}
