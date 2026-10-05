import Foundation
import PlatformKit
import Storage

/// App policy, independent of page lifetime and native transport implementation.
struct BluetoothRecoveryPolicy {
    static let maximumAttempts = 3
    static let episodeTimeout: Duration = .seconds(120)
    static let stableInterval: Duration = .seconds(30)
    static func delay(attempt: Int) -> Duration { .seconds(1 << (attempt - 1)) }

    static func canRetry(_ error: any Error, snapshot: NexArmBluetoothSnapshot) -> Bool {
        if error is CancellationError || error is DocumentStorageError { return false }
        if let native = error as? NexArmError {
            switch native {
            case .timeout, .disconnected, .io: return true
            case .invalidPacket, .overflow:
                if case .protocolViolation = snapshot.failure { return true }
                return false
            case .busy, .sessionReplaced, .invalidMotion: return false
            }
        }
        if let bluetooth = error as? NexArmBluetoothError {
            switch bluetooth {
            case .unavailable: return snapshot.power != .unauthorized && snapshot.power != .unsupported
            case .unknownDevice, .incompatibleService, .packetTooLarge: return false
            }
        }
        // Retry an untyped system error only when the SDK recorded that same native failure.
        if case .native(_, let domain, let code) = snapshot.failure {
            let system = error as NSError
            return system.domain == domain && system.code == code
        }
        return false
    }
}

enum BluetoothRecoveryCause: String {
    case disconnected = "连接意外断开"
    case congestion = "发送持续阻塞"
    case interrupted = "在途查询终止，旧连接已隔离"
    case query = "查询超时，协议已隔离"
    case transport = "设备通信异常"
    case protocolFailure = "设备协议异常"
    case power = "蓝牙暂不可用"
    case resume = "恢复已记住的设备"
    case manual = "手动重新连接"
}

enum BluetoothRecoveryError: LocalizedError {
    case episodeTimeout, disconnectUnconfirmed, notRetryable
    var errorDescription: String? {
        switch self {
        case .notRetryable: "当前错误不支持自动恢复，请检查设备后手动重连"
        case .episodeTimeout: "本轮恢复超过 2 分钟，请检查设备后手动重连"
        case .disconnectUnconfirmed: "旧连接尚未确认关闭，已停止重连"
        }
    }
}
