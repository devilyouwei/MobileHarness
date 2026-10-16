import Agents
import Foundation
import StorageAudio

/// Applied only at the host playback boundary, after audio cleanup.
public enum SpeechFailurePresentation {
    struct Failure: LocalizedError {
        let underlying: any Error
        let message: String
        var errorDescription: String? { message }
    }

    public static func adapting(_ error: any Error) -> any Error {
        let message: String
        if let producer = error as? SpeechSynthesisError {
            switch producer {
            case .invalidOutput: message = "语音合成返回了无效音频"
            }
        } else if let storage = error as? SpeechAudioError {
            switch storage {
            case .capacityExceeded: message = "语音缓冲已满，请重试"
            case .missingAudio: message = "语音任务已失效"
            case .invalidAudio: message = "语音数据格式无效"
            case .duplicate: message = "语音任务重复"
            case .forbidden: message = "语音不属于当前请求"
            case .closed: message = "语音服务已关闭"
            }
        } else {
            return error
        }
        return Failure(underlying: error, message: message)
    }
}
