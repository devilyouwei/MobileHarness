import FunctionContracts

@ActionCatalog
public struct WindowModule: CapabilityModule {
    private let windows: any WindowControlCapability
    public init(windows: any WindowControlCapability) { self.windows = windows }
    public var definitions: [ActionFunction] {
        [
            WindowActions.focusDefinition(handler: { [windows] in
                try await WindowActions.focus(invocation: $0, using: windows)
            }),
            WindowActions.minimizeDefinition(handler: { [windows] in
                try await WindowActions.minimize(invocation: $0, using: windows)
            }),
            WindowActions.maximizeDefinition(handler: { [windows] in
                try await WindowActions.maximize(invocation: $0, using: windows)
            }),
            WindowActions.restoreDefinition(handler: { [windows] in
                try await WindowActions.restore(invocation: $0, using: windows)
            }),
            WindowActions.moveDefinition(handler: { [windows] in
                try await WindowActions.move(invocation: $0, using: windows)
            }),
            WindowActions.closeDefinition(handler: { [windows] in
                try await WindowActions.close(invocation: $0, using: windows)
            }),
        ]
    }
}
