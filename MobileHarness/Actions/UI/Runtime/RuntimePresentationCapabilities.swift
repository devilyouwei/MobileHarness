import Foundation
import FunctionContracts

/// Commits diagnostic presentation; classification and toast selection remain with the caller.
public protocol RuntimeFailurePresentationCapability: Sendable {
    func recordRuntimeFailure(_ issue: RuntimeIssue, invocation: any FunctionInput) async throws
}

public enum BluetoothPresentationPhase: String, Sendable { case disconnected, connecting, connected }
public protocol BluetoothStatusPresentationCapability: Sendable {
    func presentBluetoothHome(_ phase: BluetoothPresentationPhase, revision: UInt64, invocation: any FunctionInput)
        async throws
    func presentBluetoothSettings(_ phase: BluetoothPresentationPhase, revision: UInt64, invocation: any FunctionInput)
        async throws
}
