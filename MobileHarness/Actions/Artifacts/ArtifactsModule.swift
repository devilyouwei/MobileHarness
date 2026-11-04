import FunctionContracts

@ActionCatalog public struct ArtifactsModule: CapabilityModule {
    private let artifacts: any ArtifactCapability
    public init(artifacts: any ArtifactCapability) { self.artifacts = artifacts }
    public var definitions: [ActionFunction] {
        [
            ArtifactsActions.performDefinition(completing: { [artifacts] in
                .value(try await ArtifactsActions.perform(invocation: $0, using: artifacts))
            })
        ]
    }
}
