import Foundation
import FunctionContracts

public enum BluetoothPresentationPhase: String, Sendable { case disconnected, connecting, connected }
public protocol BluetoothStatusPresentationCapability: Sendable {
    func presentBluetoothHome(_ phase: BluetoothPresentationPhase, revision: UInt64, invocation: any FunctionInput)
        async throws
    func presentBluetoothSettings(_ phase: BluetoothPresentationPhase, revision: UInt64, invocation: any FunctionInput)
        async throws
}
