import Foundation

public enum AudioDetectionError: LocalizedError, Sendable {
    case captureEnded, perceptionFailed, microphoneDenied, invalidFormat, overflow, busy, routeChanged, interrupted
    public var errorDescription: String? {
        switch self {
        case .captureEnded: "未收到音频，请重新检测。"
        case .perceptionFailed: "方向计算已停止，请重新检测。"
        case .microphoneDenied: "请在系统设置中允许麦克风访问。"
        case .invalidFormat: "当前音频格式不可用，请重新检测。"
        case .overflow: "音频处理未跟上，请重新检测。"
        case .busy: "音频正在使用中，请稍后重新检测。"
        case .routeChanged: "音频设备已变化，请重新检测。"
        case .interrupted: "录音被中断，请重新检测。"
        }
    }
}
