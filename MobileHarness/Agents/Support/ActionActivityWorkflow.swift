import ActionBindings
import AgentCore
import Foundation
import PlatformKit
import StorageCore
import UI

/// Root-owned execution-state subscription. The injected stream carries full snapshots, bounded error descriptions without call arguments.
@MainActor
public final class ActionActivityWorkflow: ExecutionFailureReporting {
    public let state: ActionActivityState
    private var taskObservation: Task<Void, Never>?
    private var agentObservation: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var failureObservation: Task<Void, Never>?
    public init(state: ActionActivityState) { self.state = state }
    deinit {
        taskObservation?.cancel()
        agentObservation?.cancel()
        observation?.cancel()
        failureObservation?.cancel()
    }
    public func recordFailure(
        title: String, source: String, message: String, failureCode: String? = nil,
        context: ExecutionIssue.Context? = nil
    ) {
        state.recordIssue(
            .init(
                title: title, source: source, message: message, failureCode: failureCode, context: context,
                userMessage: Self.userMessage(source: source, message: message, code: failureCode)))
    }
    private static func userMessage(source: String, message: String, code: String? = nil) -> String? {
        switch code {
        case "agent.model.tool.undeclaredName": return "模型调用了未声明的工具，本次回复已中止"
        case "agent.model.tool.invalidArguments": return "模型返回的工具参数格式错误，本次回复已中止"
        case "agent.model.tool.argumentsMismatch": return "模型返回的工具参数前后不一致，本次回复已中止"
        case "agent.model.tool.invalidIdentity", "agent.model.tool.sequenceMismatch":
            return "模型返回的工具调用信息不一致，本次回复已中止"
        case "agent.model.transport": return "模型连接失败，请检查网络后重试"
        case "agent.model.httpStatus", "agent.model.provider": return "模型服务请求失败，本次回复已中止"
        case let code? where code.hasPrefix("agent.model."): return "模型响应格式异常，本次回复已中止"
        case let code? where code.hasPrefix("agent.generation."): return "模型输出的指令格式异常，本次回复已中止"
        case "agent.runtime.failed": return "对话处理失败，请查看日志"
        case "agent.context.publication": return "对话上下文更新失败，本次回复已中止"
        default:
            return source == "speechPerception" && message.hasPrefix("agent.error: speech perception:") ? "我没听清" : nil
        }
    }
    private static func categoryTitle(_ category: AgentFailureDiagnostic.Category) -> String {
        switch category {
        case .modelResponse: "模型响应异常"
        case .modelTransport: "模型连接异常"
        case .generation: "指令生成异常"
        case .context: "上下文异常"
        case .runtime: "Agent 运行异常"
        }
    }

    public func startFailures(observe: @escaping @Sendable () async throws -> AsyncStream<OutputFailureSnapshot>) {
        guard failureObservation == nil else { return }
        let state = state
        failureObservation = Task {
            do {
                let stream = try await observe()
                for await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    state.replaceIssues(
                        revision: snapshot.revision,
                        records: snapshot.records.map {
                            .init(
                                id: $0.id, title: $0.title, source: $0.source.rawValue, message: $0.message,
                                time: $0.time, failureCode: $0.failureCode,
                                context: .init(
                                    workerID: $0.source.rawValue, sessionID: $0.sessionID,
                                    inputID: $0.inputID, roundID: $0.roundID),
                                inputID: $0.inputID,
                                userMessage: Self.userMessage(
                                    source: $0.source.rawValue, message: $0.message, code: $0.failureCode),
                                category: $0.diagnostic.map { Self.categoryTitle($0.category) })
                        }, evictedCount: snapshot.evictedCount)
                }
            } catch {
                if !Task.isCancelled { state.observationUnavailable = true }
            }
        }
    }

    public func startTasks(
        observe: @escaping @Sendable () async throws -> AsyncStream<SignalTraceSnapshot>,
        taskContent: @escaping @Sendable (AgentTaskSignal) -> (String, Bool) = { _ in ("", false) }
    ) {
        guard taskObservation == nil else { return }
        let state = state
        taskObservation = Task {
            do {
                let stream = try await observe()
                var previousRevision: UInt64?
                var projected: [String: String] = [:]
                for await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    guard previousRevision == nil || snapshot.revision > previousRevision! else { continue }
                    previousRevision = snapshot.revision
                    let retained = Set(snapshot.records.map(\.id))
                    projected = projected.filter { retained.contains($0.key) }
                    for record in snapshot.records {
                        guard let signal = record.task, signal.businessContract != "runtime.replyFinished" else {
                            continue
                        }
                        let key = record.phase.rawValue
                        guard projected[record.id] != key else { continue }
                        projected[record.id] = key
                        let (text, waiting) = taskContent(signal)
                        let phase: TaskLogItem.Phase
                        if record.phase == .rejected || record.phase == .dropped {
                            // A rejected progress/input/result is not proof the underlying task failed.
                            guard signal.kind == .request else { continue }
                            phase = .failed
                        } else if record.phase != .accepted {
                            phase = .requested
                        } else {
                            switch signal.kind {
                            case .request: phase = .accepted
                            case .input: phase = .running
                            case .progress: phase = waiting ? .waitingUser : .running
                            case .cancel: phase = .cancelling
                            case .result:
                                switch signal.status {
                                case .succeeded: phase = .succeeded
                                case .cancelled: phase = .cancelled
                                default: phase = .failed
                                }
                            }
                        }
                        // Unaccepted non-request reports cannot change task progress.
                        guard signal.kind == .request || record.phase == .accepted else { continue }
                        var value = TaskLogItem(
                            id: signal.scope.id, parentID: signal.scope.parentID,
                            requester: signal.scope.requester.rawValue, executor: signal.scope.executor.rawValue,
                            title: signal.kind == .request ? (signal.goal ?? text) : "", phase: phase)
                        value.execution = signal.scope.execution.rawValue
                        value.skills = signal.requestedSkills ?? []
                        state.updateTask(
                            value,
                            event: .init(
                                id: record.id, time: record.time,
                                title: signal.kind.logTitle + " · " + record.phase.displayTitle, detail: text))
                    }
                }
            } catch {
                if !Task.isCancelled {
                    state.recordIssue(
                        .init(title: "Task 记录不可用", source: "runtime", message: String(describing: error)))
                }
            }
        }
    }
    public func startAgents(statuses: @escaping @Sendable () async -> [(String, AgentLifecycle)]) {
        guard agentObservation == nil else { return }
        let state = state
        agentObservation = Task {
            var previous: [String: AgentLifecycle] = [:]
            while !Task.isCancelled {
                let values = await statuses()
                guard !Task.isCancelled else { return }
                let current = Dictionary(uniqueKeysWithValues: values)
                for (source, lifecycle) in values where previous[source] != lifecycle {
                    state.recordAgentEvent(
                        .init(source: source, status: lifecycle.logTitle, isFailure: lifecycle == .failed))
                }
                for source in previous.keys where current[source] == nil {
                    state.recordAgentEvent(.init(source: source, status: "已移除", isFailure: false))
                }
                previous = current
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    public func start(observe: @escaping @Sendable () async throws -> AsyncStream<ActionExecutionSnapshot>) {
        guard observation == nil else { return }
        let state = state
        observation = Task {
            do {
                let stream = try await observe()
                for await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    state.replace(
                        revision: snapshot.revision, records: snapshot.records.map(ActionActivityItem.init),
                        evictedCount: snapshot.evictedCount)
                }
            } catch {
                if !Task.isCancelled { state.observationUnavailable = true }
            }
        }
    }
}
