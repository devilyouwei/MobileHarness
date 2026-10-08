import FunctionContracts

public struct NavigationModule: CapabilityModule {
    private let presentation: any ResourcePresentationCapability
    public init(presentation: any ResourcePresentationCapability) { self.presentation = presentation }
    public var definitions: [ActionFunction] {
        [
            UIActions.openDefinition(completing: { [presentation] in
                .value(try await UIActions.open(invocation: $0, using: presentation))
            })
        ]
    }
}
