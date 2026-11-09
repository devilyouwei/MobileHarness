import FunctionContracts

@ActionCatalog
public struct ResourcePresentationModule: CapabilityModule {
    private let inventory: any ModelResourceInventoryCapability
    private let presentation: any ResourcePresentationCapability
    public init(inventory: any ModelResourceInventoryCapability, presentation: any ResourcePresentationCapability) {
        self.inventory = inventory
        self.presentation = presentation
    }
    public var definitions: [ActionFunction] {
        [
            UIActions.showProviderResultDefinition(handler: { [presentation] invocation in
                try await UIActions.showProviderResult(invocation: invocation, using: presentation)
            }),
            UIActions.showResourcesDefinition(completing: { [inventory, presentation] invocation in
                .value(
                    try await UIActions.showResources(invocation: invocation, inventory: inventory, using: presentation)
                )
            }),
            UIActions.showResourcePreferenceFailureDefinition(handler: { [presentation] invocation in
                try await UIActions.showResourcePreferenceFailure(invocation: invocation, using: presentation)
            }),
            UIActions.showResourceOperationFailureDefinition(handler: { [presentation] invocation in
                try await UIActions.showResourceOperationFailure(invocation: invocation, using: presentation)
            }),
            UIActions.showResourceFailureDefinition(handler: { [presentation] invocation in
                try await UIActions.showResourceFailure(invocation: invocation, using: presentation)
            }),
        ]
    }
}
