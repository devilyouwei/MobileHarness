import AgentCore
import Foundation
import UI

/// Root-owned presentation adapter. The injected stream carries full snapshots, bounded error descriptions without call arguments.
@MainActor
public final class ActionActivityWorkflow {
    public let state: ActionActivityState
    private var observation: Task<Void, Never>?
    public init(state: ActionActivityState) { self.state = state }
    deinit { observation?.cancel() }

    public func start(observe: @escaping @Sendable () async throws -> AsyncStream<ActionExecutionSnapshot>) {
        guard observation == nil else { return }
        let state = state
        observation = Task {
            do {
                let stream = try await observe()
                for await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    state.replace(
                        revision: snapshot.revision, items: snapshot.records.map(Self.present),
                        evictedCount: snapshot.evictedCount)
                }
            } catch {
                if !Task.isCancelled { state.observationUnavailable = true }
            }
        }
    }

    public static func present(_ record: ActionExecutionRecord) -> ActionActivityItem {
        let title: String
        switch (record.path.module, record.path.function) {
        case ("NexArm", "shakeBase"): title = "底座晃动"
        case ("NexArm", "nodHead"): title = "点头"
        case ("NexArm", "shakeHead"): title = "摇头"
        case ("NexArm", "waveWrist"): title = "挥手"
        case ("NexArm", "tiltWrist"): title = "歪头"
        case ("NexArm", "lookAround"): title = "左右张望"
        case ("NexArm", "celebrate"): title = "庆祝"
        case ("NexArm", "dance"): title = "跳舞"
        case ("NexArm", "nudgeWrist"): title = "调整机械臂"
        case ("Speech", "speak"): title = "朗读回复"
        case ("UI", "express"): title = "调整表情"
        default: title = "执行动作"
        }
        let channel: String
        switch record.channel.lowercased() {
        case "robot", "arm": channel = "机械臂"
        case "speech": channel = "语音"
        case "display", "ui": channel = "画面"
        case "vision", "camera": channel = "视觉"
        case "gaze": channel = "视线"
        case "transcript", "recognition": channel = "识别"
        default: channel = "其他"
        }
        let status: String
        switch record.phase {
        case .queued: status = "等待执行"
        case .running: status = "正在执行"
        case .cancelling: status = "正在结束当前动作"
        case .cancelled: status = record.startedAt == nil ? "执行前已取消" : "已取消后续动作"
        case .succeeded:
            switch record.completion {
            case .activityStarted: status = "已启动"
            case .activityStopped: status = "已结束"
            default:
                status = record.semantics == .state || record.semantics == .activityUpdate ? "已设置" : "已完成"
            }
        case .failed:
            status = record.failureDescription ?? "执行未完成"
        }
        return ActionActivityItem(execution: record, title: title, channelTitle: channel, status: status)
    }
}
