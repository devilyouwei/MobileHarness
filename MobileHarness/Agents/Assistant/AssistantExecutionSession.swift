import AgentCore
import Foundation
import Gateway
import PlatformKit
import StorageCore
import UI

/// Application-owned entry transport. Admission never waits for reasoning or child completion.
public actor AssistantExecutionSession {
    public nonisolated let agent: AssistantAgent
    public private(set) var cleanupFailure: AgentFailure?
    let speech: AssistantSpeechOutput?
    private let island = AgentIslandPublication()
    private let waitingIsland = AgentIslandPublication()
    private let decisionIsland = AgentIslandPublication()
    private var decisionExpiry: Task<Void, Never>?
    private var decisionRevision: UInt64 = 0
    private var allowsDecisionPresentation = true
    public var presentationFailure: String? {
        get async {
            let failures = [
                await island.lastFailure, await waitingIsland.lastFailure, await decisionIsland.lastFailure,
                await speech?.snapshot().presentationFailure,
            ]
            .compactMap { $0 }
            return failures.isEmpty ? nil : failures.joined(separator: "; ")
        }
    }
    private var registeredForCleanup = false
    private let manager: AgentManager
    private let output: OutputGateway
    private let report: @Sendable (String) async -> Void
    private var starting: Task<Void, Error>?
    private var closing: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    private var started = false
    private var closed = false

    public init(
        agent: AssistantAgent, manager: AgentManager, output: OutputGateway,
        report: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.speech = nil
        self.agent = agent
        self.manager = manager
        self.output = output
        self.report = report
    }

    init(
        agent: AssistantAgent, manager: AgentManager, output: OutputGateway, speech: AssistantSpeechOutput,
        report: @escaping @Sendable (String) async -> Void
    ) {
        self.agent = agent
        self.manager = manager
        self.output = output
        self.speech = speech
        self.report = report
    }

    public func start() async throws {
        guard !closed else { throw CommunicationError.scopeClosed }
        if started { return }
        if let starting {
            try await starting.value
            return
        }
        let operation = Task {
            try await manager.register(agent)
            registeredForCleanup = true
            do {
                try Task.checkCancellation()
                try await manager.start(.assistant)
                let consumer = try await output.consumer(for: agent)
                await agent.bindInputInterruption { [weak self] session in
                    try await self?.interruptConversation(sessionID: session)
                }
                await island.bind { operation, parameters, session in
                    let result = try await consumer.executeInternal(
                        .init(
                            source: .assistant, context: .init(sessionID: session, source: "assistant"),
                            output: .toolCall(
                                .init(id: UUID().uuidString, toolPath: "UI.Island." + operation, arguments: parameters)),
                            sequence: UInt64(parameters["revision"] ?? "") ?? 0))
                    if result.isCancellationOnly { throw CancellationError() }
                    guard !result.isError, result.tool != nil else {
                        throw AgentFailure(
                            component: "assistant", operation: "island." + operation,
                            underlying: NSError(
                                domain: "Island", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: result.failure ?? "Island presentation rejected"])
                        )
                    }
                }
                await island.start()
                await waitingIsland.bind(consumer: consumer, source: .assistant)
                await waitingIsland.start()
                await decisionIsland.bind(consumer: consumer, source: .assistant)
                await decisionIsland.start()
                await agent.bindInputDecisionFeedback { [weak self] disposition, id in
                    await self?.presentInputDecision(disposition, id: id)
                }
                await speech?.bindPresentation(consumer)
                await agent.bindReplyWaiting { [waitingIsland] waiting in
                    await waitingIsland.submit(waiting ? Self.waitingContent : nil)
                }
                pump = Task {
                    do {
                        try await AssistantGenerationTransport.consume(agent.outputs) { envelope in
                            do {
                                let outcome = try await consumer.execute(envelope)
                                if outcome.isError {
                                    await self.report(
                                        outcome.failure ?? outcome.tool?.value ?? "Agent execution failed")
                                }
                            } catch is CancellationError {
                                // Explicit host cancellation releases a playback seal without closing this reader.
                                try Task.checkCancellation()
                            } catch { await self.report("Agent output failed: \(error)") }
                            if case .control(let value) = envelope.output,
                                value == "agent.finished" || value == "agent.cancelled"
                                    || value.hasPrefix("agent.error:")
                            {
                                // The execution boundary has drained or rejected its effects. Retire orphaned handles too.
                                await self.speech?.cancel(
                                    input: AgentInput(
                                        id: envelope.inputID, sessionID: envelope.sessionID, payload: .text("")))
                            }
                        }
                    } catch is CancellationError {} catch { await report("Agent output transport stopped: \(error)") }
                }
                guard !closed else { throw CommunicationError.scopeClosed }
                started = true
            } catch {
                await speech?.stop()
                await decisionIsland.stop()
                await waitingIsland.stop()
                await island.stop()
                await removeRegistration()
                pump?.cancel()
                await pump?.value
                pump = nil
                if let cleanupFailure {
                    throw AgentFailure(
                        component: "assistant", operation: "start", underlying: error,
                        cleanupErrors: [cleanupFailure])
                }
                throw error
            }
        }
        starting = operation
        defer { starting = nil }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    /// Only the Assistant is affected; peer lifecycle belongs to the module root.
    public func setForeground(_ foreground: Bool) async throws {
        try await start()
        allowsDecisionPresentation = foreground
        if !foreground {
            await clearInputDecision()
        }
        let state = await agent.status().lifecycle
        if foreground, state == .paused { try await agent.resume() }
        if !foreground, state == .running { try await agent.pause() }
    }

    /// Stop accepted execution without ending the conversation or its public State scope.
    public func interruptConversation(sessionID: String) async throws {
        guard started, !closed else { return }
        await agent.setExecutionCancellationBarrier(true)
        do {
            async let calls: Void = output.cancelCalls(for: agent, sessionID: sessionID)
            async let model: Void = sendControl(.interruptSession, sessionID: sessionID)
            _ = try await (model, calls)
            try await agent.settleInterruptedExecution(sessionID: sessionID)
            await agent.setExecutionCancellationBarrier(false)
        } catch {
            await agent.setExecutionCancellationBarrier(false)
            throw error
        }
    }

    /// Receives the existing role-owned Skill snapshot; task logs are not a presentation authority.
    func presentTaskState(_ skills: AgentTaskSkillState) async {
        guard !closed else { return }
        await island.submit(Self.taskContent(skills))
    }
    static func taskContent(_ skills: AgentTaskSkillState) -> IslandContent? {
        guard let task = skills.tasks.first(where: { $0.id == skills.activeTaskID }),
            !["completed", "succeeded", "cancelled", "failed", "interrupted"].contains(task.status)
        else { return nil }
        let status: String
        switch task.status {
        case "waitingUser": status = "等待你的操作"
        case "pending", "queued": status = "等待执行"
        case "paused", "suspended": status = "已暂停"
        case "cancelling": status = "正在取消"
        default: status = "正在执行"
        }
        return .init(
            title: String(task.goal.prefix(80)), subtitle: status,
            primary: .symbol(name: "scope"), tone: .blue, priority: .normal,
            secondary: ["waitingUser", "paused", "suspended"].contains(task.status) ? nil : .loading,
            liveActivity: true, expansionID: task.id,
            detail: .init(text: String(task.goal.prefix(320))))
    }

    private func presentInputDecision(_ disposition: InputDisposition, id: String) async {
        guard started, !closed, allowsDecisionPresentation,
            let content = Self.inputDecisionContent(disposition, id: id)
        else { return }
        decisionExpiry?.cancel()
        decisionRevision &+= 1
        let revision = decisionRevision
        decisionExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            await self?.expireInputDecision(revision: revision)
        }
        await decisionIsland.submit(content)
    }

    static func inputDecisionContent(_ disposition: InputDisposition, id: String) -> IslandContent? {
        let title: String
        let symbol: String
        switch disposition {
        case .enqueue: return nil
        case .discard:
            title = "已丢弃本次输入"
            symbol = "minus.circle"
        case .interrupt:
            title = "已打断当前回复"
            symbol = "stop.circle"
        }
        return .init(
            title: title, primary: .symbol(name: symbol), tone: .warning, priority: .attention,
            liveActivity: false, expansionID: id, detail: .init(text: title))
    }

    private func expireInputDecision(revision: UInt64) async {
        guard decisionRevision == revision else { return }
        decisionExpiry = nil
        await decisionIsland.submit(nil)
    }

    private func clearInputDecision() async {
        decisionRevision &+= 1
        let expiry = decisionExpiry
        decisionExpiry = nil
        expiry?.cancel()
        await decisionIsland.submit(nil)
        await expiry?.value
    }

    static var waitingContent: IslandContent {
        .init(title: "正在思考", primary: .symbol(name: "sparkles"), priority: .low, secondary: .loading)
    }
    private func sendControl(_ control: AssistantSessionControl, sessionID: String) async throws {
        try await agent.receive(control.input(sessionID: sessionID))
    }

    private func removeRegistration() async {
        guard registeredForCleanup else { return }
        do {
            try await manager.remove(.assistant)
            registeredForCleanup = false
        } catch {
            cleanupFailure = AgentFailure(
                component: "assistant", operation: "stop",
                underlying: error, code: .cleanupFailed)
        }
    }
    public func shutdown() async {
        if let closing { return await closing.value }
        closed = true
        let task = Task {
            starting?.cancel()
            _ = await starting?.result
            await speech?.stop()
            await clearInputDecision()
            await decisionIsland.stop()
            await waitingIsland.stop()
            await island.stop()
            await removeRegistration()
            pump?.cancel()
            await pump?.value
            pump = nil
        }
        closing = task
        await task.value
    }
}
