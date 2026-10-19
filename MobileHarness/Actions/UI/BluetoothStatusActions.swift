import FunctionContracts

extension UIActions {
    private static func bluetoothStatus(_ invocation: any FunctionInput) throws -> (BluetoothPresentationPhase, UInt64)
    {
        guard Set(invocation.call.parameters.keys) == ["phase", "revision"],
            let raw = invocation.call.parameters["phase"], let phase = BluetoothPresentationPhase(rawValue: raw),
            let rawRevision = invocation.call.parameters["revision"], let revision = UInt64(rawRevision), revision > 0
        else { throw PresentationError.invalidCall }
        return (phase, revision)
    }
    @Action(domain: "UI", module: "BluetoothStatus", title: "showHome", timeout: .seconds(5))
    public static func showBluetoothHome(
        invocation: any FunctionInput, using presentation: any BluetoothStatusPresentationCapability
    ) async throws -> String {
        try Task.checkCancellation()
        let (phase, revision) = try bluetoothStatus(invocation)
        try await presentation.presentBluetoothHome(phase, revision: revision, invocation: invocation)
        return "presented"
    }
    @Action(domain: "UI", module: "BluetoothStatus", title: "showSettings", timeout: .seconds(5))
    public static func showBluetoothSettings(
        invocation: any FunctionInput, using presentation: any BluetoothStatusPresentationCapability
    ) async throws -> String {
        try Task.checkCancellation()
        let (phase, revision) = try bluetoothStatus(invocation)
        try await presentation.presentBluetoothSettings(phase, revision: revision, invocation: invocation)
        return "presented"
    }
}
