import Actions
import Foundation
import PlatformKit
import Storage

/// App policy, independent of page lifetime and native transport implementation.
struct BluetoothRecoveryPolicy {
    static let maximumAttempts = 3
    static let verificationTimeout: Duration = .seconds(20)
    static let episodeTimeout: Duration = .seconds(120)
    static let stableInterval: Duration = .seconds(30)
    static func delay(attempt: Int) -> Duration { .seconds(1 << (attempt - 1)) }

    static func canRetry(_ error: any Error) -> Bool {
        if error is CancellationError || error is DocumentStorageError { return false }
        switch error as? NexArmError {
        case .busy, .invalidMotion, .unsupportedFirmware, .firmwareUnavailable: return false
        default: break
        }
        switch error as? NexArmBluetoothError {
        case .incompatibleService, .packetTooLarge: return false
        default: break
        }
        // An invalid/moving pose cannot be fixed by repeatedly reconnecting.
        if error as? NexArmActionError == .moving { return false }
        return true
    }
}

enum BluetoothRecoveryCause: String {
    case disconnected = "连接意外断开"
    case feedback = "位置反馈丢失"
    case congestion = "发送持续阻塞"
    case query = "查询超时，协议已隔离"
    case transport = "设备通信异常"
    case verification = "控制验证失败"
    case power = "蓝牙暂不可用"
    case resume = "恢复已记住的设备"
    case manual = "手动重新连接"
    case resources = "电机控制资源异常"
}

enum BluetoothRecoveryError: LocalizedError {
    case verificationTimeout, episodeTimeout, disconnectUnconfirmed
    var errorDescription: String? {
        switch self {
        case .verificationTimeout: "控制验证超过 20 秒，已停止本次连接"
        case .episodeTimeout: "本轮恢复超过 2 分钟，请检查设备后手动重连"
        case .disconnectUnconfirmed: "旧连接尚未确认关闭，已停止重连"
        }
    }
}
