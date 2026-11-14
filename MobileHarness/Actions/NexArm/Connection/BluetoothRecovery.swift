import Foundation
import FunctionContracts
import PlatformKit
import StorageCore
import StorageFiles

/// Excludes application persistence failures before consulting native recovery classification.
public struct BluetoothRecoveryPolicy {
    public static func canRetry(_ error: any Error, snapshot: NexArmBluetoothSnapshot) -> Bool {
        guard !(error is DocumentStorageError) else { return false }
        return NexArmBluetoothRecoveryPolicy.canRetry(error, snapshot: snapshot)
    }
}

public enum BluetoothRecoveryCause: String {
    case disconnected = "Connection lost"
    case congestion = "Bluetooth transmission blocked"
    case interrupted = "Device query stopped. The old connection was isolated."
    case query = "Device query timed out. The old connection was isolated."
    case transport = "Device communication failed"
    case protocolFailure = "Device protocol failure"
    case power = "Bluetooth is temporarily unavailable"
    case resume = "Reconnecting to a remembered device"
    case manual = "Reconnecting manually"
}

public typealias BluetoothRecoveryError = NexArmBluetoothRecoveryError

/// Presentation stays above the native SDK error taxonomy.
enum BluetoothRecoveryPresentation {
    static func message(_ error: NexArmBluetoothRecoveryError) -> String {
        switch error {
        case .notRetryable: "Check the device and reconnect manually."
        case .episodeTimeout: "Recovery timed out after two minutes. Check the device and reconnect manually."
        case .disconnectUnconfirmed: "Reconnection stopped because the old connection is still unconfirmed."
        }
    }
}
