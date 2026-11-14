import Foundation
import FunctionContracts
import PlatformKit
import StorageCore

/// App presentation policy, independent of packet admission and motion execution.
public enum BluetoothPresentation {
    public static func discoveryOrder(_ lhs: NexArmBluetoothDevice, _ rhs: NexArmBluetoothDevice) -> Bool {
        func preferred(_ name: String) -> Bool {
            name.lowercased().filter { $0.isLetter || $0.isNumber }.contains("nexarm")
        }
        if preferred(lhs.name) != preferred(rhs.name) { return preferred(lhs.name) }
        if lhs.rssi != rhs.rssi { return lhs.rssi > rhs.rssi }
        return lhs.id < rhs.id
    }

    public static func deviceName(_ value: String) -> String? {
        guard let name = NexArmBluetoothDevice.discoveryName(advertised: value, cached: nil),
            name != "Unnamed device", name != "未命名设备"
        else { return nil }
        return name
    }
    /// Latest native state only; no execution result or history is accepted.
    public static func currentIssue(_ snapshot: NexArmBluetoothSnapshot) -> String? {
        if let fault = snapshot.failure { return String(failure(fault).prefix(512)) }
        if snapshot.phase == .connected && !snapshot.feedbackHealthy {
            return "No new arm position feedback"
        }
        return nil
    }
    public static func failure(_ value: NexArmBluetoothFailure) -> String {
        func title(_ step: NexArmBluetoothStep) -> String {
            switch step {
            case .connecting: "Bluetooth connection"
            case .services: "Service discovery"
            case .characteristics: "Characteristic discovery"
            case .notifications: "Enabling notifications"
            case .writing: "Sending device command"
            case .response: "Waiting for device response"
            }
        }
        switch value {
        case .responseTimeout(let command, let expectedBytes, let receivedBytes):
            let query: String
            switch command {
            case 11: query = "Arm position query"
            case 1: query = "Firmware version query"
            default: query = "Device query"
            }
            let code = String(format: "0x%02X", command)
            return
                "\(query) timed out (\(code), expected \(expectedBytes) payload bytes, received \(receivedBytes) notification bytes)"
        case .timeout(let step): return "\(title(step)) timed out"
        case .incompatibleService(let step): return "\(title(step)) failed: incompatible Bluetooth service"
        case .native(let step, let domain, let code): return "\(title(step)) failed (\(domain) \(code))"
        case .protocolViolation(.invalidPacket): return "Invalid Bluetooth response packet"
        case .protocolViolation(.receiveOverflow): return "Bluetooth receive buffer overflow"
        case .requestInterrupted(let command):
            return
                "Device query stopped (\(String(format: "0x%02X", command))); old connection closed to isolate delayed responses"
        case .sendBlocked: return "Bluetooth transmission remained blocked"
        case .disconnectUnconfirmed: return "Bluetooth disconnection unconfirmed. Turn Bluetooth off, then retry."
        }
    }
}
