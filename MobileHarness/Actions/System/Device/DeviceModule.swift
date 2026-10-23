import FunctionContracts

@ActionCatalog
public struct DeviceModule: CapabilityModule {
    private let device: any DeviceControlCapability
    public init(device: any DeviceControlCapability) { self.device = device }
    public var definitions: [ActionFunction] {
        [
            SystemActions.readEnvironmentDefinition(completing: { [device] in
                .value(try await SystemActions.readEnvironment(invocation: $0, using: device))
            }),
            SystemActions.controlDefinition(completing: { [device] in
                .value(try await SystemActions.control(invocation: $0, using: device))
            }),
            SystemActions.readStatusDefinition(completing: { [device] in
                .value(try await SystemActions.readStatus(invocation: $0, using: device))
            }),
        ]
    }
}
