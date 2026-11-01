import FunctionContracts

@ActionCatalog
public struct WindowModule: CapabilityModule {
    private let windows: any WindowControlCapability
    public init(windows: any WindowControlCapability) { self.windows = windows }
    public var definitions: [ActionFunction] {
        [
            WindowActions.focusDefinition(completing: { [windows] in
                .value(try await WindowActions.focus(invocation: $0, using: windows))
            }),
            WindowActions.minimizeDefinition(completing: { [windows] in
                .value(try await WindowActions.minimize(invocation: $0, using: windows))
            }),
            WindowActions.maximizeDefinition(completing: { [windows] in
                .value(try await WindowActions.maximize(invocation: $0, using: windows))
            }),
            WindowActions.restoreDefinition(completing: { [windows] in
                .value(try await WindowActions.restore(invocation: $0, using: windows))
            }),
            WindowActions.moveDefinition(completing: { [windows] in
                .value(try await WindowActions.move(invocation: $0, using: windows))
            }),
            WindowActions.closeDefinition(completing: { [windows] in
                .value(try await WindowActions.close(invocation: $0, using: windows))
            }),
        ]
    }
}
