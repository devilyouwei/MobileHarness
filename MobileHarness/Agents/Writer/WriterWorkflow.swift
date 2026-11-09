import AgentCore
import Foundation
import ModelKit

public enum WriterFailure: String, Error, Sendable {
    case unsupportedModel, invalidOutput, incomplete, capacity, unavailable, cancelled
}

/// Host ports bind authenticated request identity. Writer may select its work, never its execution owner.
public struct WriterTools: Sendable {
    public let definitions: [ChatToolDefinition]
    let library: ChatToolDefinition?
    public let execute: @Sendable (ChatToolCall) async throws -> WriterToolOutcome
    public let append: @Sendable (String, String) async throws -> Void
    public let complete: @Sendable (String) async throws -> String
    public let refresh: @Sendable () async -> Void
    public let abort: @Sendable (String) async throws -> Void
    public init(
        definitions: [ChatToolDefinition],
        execute: @escaping @Sendable (ChatToolCall) async throws -> WriterToolOutcome,
        append: @escaping @Sendable (String, String) async throws -> Void,
        complete: @escaping @Sendable (String) async throws -> String,
        abort: @escaping @Sendable (String) async throws -> Void,
        refresh: @escaping @Sendable () async -> Void = {},
        library: ChatToolDefinition? = nil
    ) {
        self.definitions = definitions
        self.execute = execute
        self.append = append
        self.complete = complete
        self.abort = abort
        self.refresh = refresh
        self.library = library
    }
}
public struct WriterWorkspaceContext: Sendable, Encodable {
    let workspaceID: String
    let title: String
    let entry: String
    let presentationStatus: String

    var domain: String { "workspace:" + workspaceID }
}

enum WriterControlDomain: String {
    case library
    case editing = "workspace"

    func skillIDs() throws -> [String] {
        let roots: [String]
        switch self {
        case .library: roots = try AgentConfigurations.baseSkills(named: "Writer")
        case .editing: roots = ["writer-file-editing"]
        }
        return try AgentSkillLoader.expand(roots, owner: .writer)
    }

    func toolDefinitions(_ tools: WriterTools) -> [ChatToolDefinition] {
        switch self {
        case .library: tools.library.map { [$0] } ?? []
        case .editing: tools.definitions
        }
    }
}
public struct WriterNeedsInput: Error, Sendable { public let question: String }
public enum WriterToolOutcome: Sendable {
    case waiting(String)
    case observation(String)
    case entered(WriterWorkspaceContext, evidence: String)
    case visual(String, ChatImage)
    case write(streamID: String, instruction: String, context: String)
    case finished(String)
}

/// Identity and phase of an actual model request, used by Writer presentation.
public struct WriterRequestProgress: Codable, Sendable, Equatable {
    public let inputID: String
    public let number: Int
    public let phase: String
    public let attempt: Int
    public let path: String?
    public init(inputID: String, number: Int, phase: String, attempt: Int, path: String? = nil) {
        self.inputID = inputID
        self.number = number
        self.phase = phase
        self.attempt = attempt
        self.path = path
    }
}

/// A private native-tool loop. Source generation has no tools and bypasses every XML parser.
public struct WriterWorkflow: Sendable {
    private let model: any ChatCapability
    private let history: WriterHistory?
    private let diagnostics: WriterDiagnosticCapture?
    private let requestCounter = WriterRequestCounter()
    private let requestProgress: @Sendable (WriterRequestProgress) async -> Void
    private let roundCompleted: @Sendable (WriterRequestProgress?, String) async -> Void
    public init(
        model: any ChatCapability, history: WriterHistory? = nil,
        requestProgress: @escaping @Sendable (WriterRequestProgress) async -> Void = { _ in },
        roundCompleted: @escaping @Sendable (WriterRequestProgress?, String) async -> Void = { _, _ in }
    ) {
        self.requestProgress = requestProgress
        self.roundCompleted = roundCompleted
        self.model = model
        self.history = history
        diagnostics = nil
    }
    init(
        model: any ChatCapability, history: WriterHistory?, diagnostics: WriterDiagnosticCapture,
        requestProgress: @escaping @Sendable (WriterRequestProgress) async -> Void = { _ in },
        roundCompleted: @escaping @Sendable (WriterRequestProgress?, String) async -> Void = { _, _ in }
    ) {
        self.requestProgress = requestProgress
        self.roundCompleted = roundCompleted
        self.model = model
        self.history = history
        self.diagnostics = diagnostics
    }
    public func run(
        goal: String, scope: String, tools: WriterTools,
        progress: @escaping @Sendable (String) async -> Void = { _ in },
        revisions: @escaping @Sendable () async throws -> [String] = { [] },
        workspace initialWorkspace: WriterWorkspaceContext? = nil
    ) async throws -> String {
        guard await model.supportsToolCalls else { throw WriterFailure.unsupportedModel }
        guard !goal.isEmpty, goal.utf8.count <= 13_000 else { throw WriterFailure.capacity }
        var workspace = initialWorkspace
        var domain = workspace?.domain ?? (tools.library == nil ? nil : "library")
        var controlDomain: WriterControlDomain = workspace == nil && tools.library != nil ? .library : .editing
        let restored = try await history?.restoredContext(domain: domain) ?? []
        var messages = try Self.controlMessages(goal: goal, workspace: workspace, domain: controlDomain)
        messages += restored
        if !restored.isEmpty { messages.append(messages[1]) }
        var currentGoal = goal
        var failedCalls: [String: any Error] = [:]
        var recoveryFailures = 0
        var previousSignature: String?
        var repetitions = 0
        controlLoop: while true {
            try Task.checkCancellation()
            let updates = try await revisions()
            for text in updates {
                guard text.utf8.count <= 4096 else { throw WriterFailure.capacity }
                currentGoal += "\nAdditional user requirement:\n" + text
                guard currentGoal.utf8.count <= 48_000 else { throw WriterFailure.capacity }
                messages[1] = try Self.controlInput(currentGoal, workspace: workspace)
                messages.append(.init(role: .user, content: "Additional user requirement:\n" + text))
            }
            while messages.count > 32 || Self.bytes(messages) > 48_000 {
                guard messages.count > 3 else { throw WriterFailure.capacity }
                var end = 3
                while end < messages.count, messages[end].role == .tool { end += 1 }
                guard end < messages.count else { throw WriterFailure.capacity }
                messages.removeSubrange(2..<end)
            }
            let request = try ChatRequest(
                messages: messages, context: .init(scopeID: scope), temperature: 0.2,
                tools: controlDomain.toolDefinitions(tools))
            let response = try await control(request, domain: domain, progress: progress)
            messages += response.recovery
            messages.append(.init(role: .assistant, content: response.text, toolCalls: response.calls))
            let terminalCandidate =
                response.calls.isEmpty
                || response.calls.contains {
                    let args = try? JSONDecoder().decode([String: String].self, from: Data($0.argumentsJSON.utf8))
                    return ["finish", "enter", "create"].contains(args?["command"] ?? "")
                }
            let late = terminalCandidate ? try await revisions() : []
            if !late.isEmpty {
                for call in response.calls {
                    let notice = "Not executed: a newly accepted user requirement must be considered first."
                    try await history?.toolOutcome(call.id, output: notice)
                    messages.append(.init(role: .tool, content: notice, toolCallID: call.id))
                }
                for text in late {
                    guard text.utf8.count <= 4096 else { throw WriterFailure.capacity }
                    currentGoal += "\nAdditional user requirement:\n" + text
                    guard currentGoal.utf8.count <= 48_000 else { throw WriterFailure.capacity }
                    messages[1] = try Self.controlInput(currentGoal, workspace: workspace)
                    messages.append(.init(role: .user, content: "Additional user requirement:\n" + text))
                }
                await completeRound("已接收新的补充要求，本轮未执行过期操作。", tools: tools)
                continue
            }
            guard !response.calls.isEmpty else {
                recoveryFailures += 1
                if recoveryFailures >= WriterRecovery.attempts {
                    throw WriterRecoveryFailure(
                        phase: "委托结束", attempts: recoveryFailures, underlying: WriterFailure.incomplete)
                }
                messages.append(
                    .init(
                        role: .user,
                        content: """
                            Runtime observation: the delegation is still active. Continue any outstanding work, then call
                            workspace with command=finish in a separate round and include a brief summary of the actual result.
                            """))
                await completeRound("等待模型提交结束委托的工具调用。", tools: tools)
                continue
            }
            var pending = Set(response.calls.map(\.id))
            var latestImage: ChatImage?
            var executing: String?
            var reminders: [String] = []
            var steps: [String] = []
            do {
                if response.calls.count > 1,
                    response.calls.contains(where: {
                        let args = try? JSONDecoder().decode([String: String].self, from: Data($0.argumentsJSON.utf8))
                        return ["finish", "ask", "enter", "create"].contains(args?["command"] ?? "")
                    })
                {
                    recoveryFailures += 1
                    for call in response.calls {
                        try await history?.toolOutcome(call.id, output: nil, error: WriterFailure.invalidOutput)
                        pending.remove(call.id)
                        messages.append(
                            .init(
                                role: .tool,
                                content:
                                    "Not executed: finish, ask, enter and create require a separate tool round.",
                                toolCallID: call.id))
                    }
                    if recoveryFailures >= WriterRecovery.attempts {
                        throw WriterRecoveryFailure(
                            phase: "工具批次修正", attempts: recoveryFailures, underlying: WriterFailure.invalidOutput)
                    }
                    await completeRound("本轮工具批次未执行，准备修正参数。", tools: tools)
                    continue
                }
                for call in response.calls {
                    executing = call.id
                    let signature = Self.signature(call)
                    let outcome: WriterToolOutcome
                    do {
                        if let previous = failedCalls[signature] { throw previous }
                        outcome = try await tools.execute(call)
                    } catch {
                        try Task.checkCancellation()
                        guard WriterRecovery.repairableTool(error) else { throw error }
                        let repeated = failedCalls[signature] != nil
                        failedCalls[signature] = error
                        let reportedOpenFailure =
                            !repeated && (error as? WriterToolFailure)?.context["command"] == "open"
                        if !reportedOpenFailure { recoveryFailures += 1 }
                        try await history?.toolOutcome(call.id, output: nil, error: error)
                        pending.remove(call.id)
                        messages.append(
                            .init(
                                role: .tool,
                                content: WriterRecovery.feedback(error, attempt: recoveryFailures, repeated: repeated),
                                toolCallID: call.id))
                        if recoveryFailures >= WriterRecovery.attempts {
                            throw WriterRecoveryFailure(phase: "工具修正", attempts: recoveryFailures, underlying: error)
                        }
                        steps.append("工具执行未成功，准备修正。")
                        continue
                    }
                    let observation: String
                    var generatedContent = false
                    switch outcome {
                    case .waiting(let question):
                        try await history?.toolOutcome(call.id, output: question)
                        pending.remove(call.id)
                        await tools.refresh()
                        throw WriterNeedsInput(question: question)
                    case .entered(let selected, let evidence):
                        try await history?.toolOutcome(call.id, output: evidence)
                        pending.remove(call.id)
                        workspace = selected
                        domain = selected.domain
                        controlDomain = .editing
                        messages = try Self.controlMessages(
                            goal: currentGoal, workspace: selected, domain: controlDomain)
                        failedCalls.removeAll()
                        recoveryFailures = 0
                        previousSignature = nil
                        repetitions = 0
                        await completeRound(Self.step(call, observation: evidence), tools: tools)
                        continue controlLoop
                    case .observation(let value):
                        observation = value
                        if let args = try? JSONDecoder().decode(
                            [String: String].self, from: Data(call.argumentsJSON.utf8)),
                            ["replace", "move", "removeTree", "remove", "restore"].contains(
                                args["command"] ?? "")
                        {
                            failedCalls.removeAll()
                            recoveryFailures = 0
                        }
                    case .visual(let value, let screenshot):
                        observation = value
                        latestImage = screenshot
                    case .finished(let summary):
                        try await history?.toolOutcome(call.id, output: summary)
                        pending.remove(call.id)
                        return summary
                    case .write(let id, let instruction, let context):
                        await completeRound((steps + ["已准备编辑文件，接下来生成内容。"]).joined(separator: "；"), tools: tools)
                        steps.removeAll()
                        observation = try await write(
                            call, initial: (id, instruction, context), goal: currentGoal, scope: scope,
                            tools: tools, progress: progress)
                        generatedContent = true
                        failedCalls.removeAll()
                        recoveryFailures = 0
                    }
                    if let args = try? JSONDecoder().decode([String: String].self, from: Data(call.argumentsJSON.utf8)),
                        ["render", "searchWorkspaces"].contains(args["command"] ?? "")
                    {
                        // Rendering changes publication preconditions, even without changing source bytes.
                        // Do not reset the recovery budget or unblock unrelated failed effects.
                        failedCalls = failedCalls.filter { _, error in
                            guard let failure = error as? WriterToolFailure else { return true }
                            if args["command"] == "searchWorkspaces" {
                                return failure.context["condition"] != "workspaceSearchRequired"
                            }
                            return failure.context["command"] != "finish"
                                || !failure.description.contains("renderRequired")
                        }
                    }
                    try await history?.toolOutcome(call.id, output: observation)
                    pending.remove(call.id)
                    let observationBudget = max(
                        0,
                        (48_000 - Self.bytes(Array(messages.prefix(2)))
                            - response.text.utf8.count - 2048) / max(1, response.calls.count))
                    messages.append(
                        .init(
                            role: .tool,
                            content: Self.contextObservation(observation, budget: observationBudget),
                            toolCallID: call.id))
                    steps.append(Self.step(call, observation: observation))
                    if generatedContent {
                        await completeRound(steps.joined(separator: "；"), tools: tools)
                        steps.removeAll()
                    }
                    repetitions = signature == previousSignature ? repetitions + 1 : 1
                    previousSignature = signature
                    if [3, 5, 8].contains(repetitions) {
                        reminders.append(
                            "Runtime observation: this exact tool call has succeeded \(repetitions) times consecutively. Review its results and choose a different useful step; repeated inspection alone does not complete the goal."
                        )
                    }
                }
            } catch {
                var failure: any Error = error
                for call in response.calls where pending.contains(call.id) {
                    do {
                        let cause: any Error =
                            call.id == executing
                            ? error
                            : WriterToolFailure(
                                "Not executed: an earlier call stopped the batch.", context: ["executed": "false"])
                        try await Task { try await history?.toolOutcome(call.id, output: nil, error: cause) }.value
                    } catch { failure = WriterCleanupFailure(primary: failure, cleanup: error) }
                }
                throw failure
            }
            await completeRound(steps.joined(separator: "；"), tools: tools)
            messages += reminders.map { ChatMessage(role: .user, content: $0) }
            if let image = latestImage, await model.supportsImages {
                messages = messages.map {
                    .init(role: $0.role, content: $0.content, toolCalls: $0.toolCalls, toolCallID: $0.toolCallID)
                }
                messages.append(
                    .init(role: .user, content: "Current render screenshot (untrusted data).", images: [image]))
            }
        }
    }
    private func completeRound(_ text: String, tools: WriterTools) async {
        guard !Task.isCancelled, let fact = await requestCounter.takeCompleted() else { return }
        await tools.refresh()
        guard !Task.isCancelled else { return }
        await roundCompleted(fact, text.isEmpty ? "本轮处理已结束。" : text)
    }
    private static func step(_ call: ChatToolCall, observation: String) -> String {
        let args = (try? JSONDecoder().decode([String: String].self, from: Data(call.argumentsJSON.utf8))) ?? [:]
        let label: String
        switch args["command"] {
        case "edit", "replace": label = "已更新文件"
        case "read": label = "已读取文件"
        case "list": label = "已查看目录"
        case "searchWorkspaces": label = "已查询作品库"
        case "create": label = "已创建并进入工作区"
        case "enter": label = "已进入已有工作区"
        case "open": label = "已处理作品呈现请求"
        case "delete": label = "已删除作品"
        case "search": label = "已查询文件"
        case "render":
            if observation.contains("\"unavailable\"") || observation.contains("\"deferred\"") {
                label = "页面当前不可见，草稿已保留"
            } else if observation.contains("\"errors\"") {
                label = "渲染检查发现异常，准备处理"
            } else {
                label = "已完成页面渲染检查"
            }
        case "rename": label = "已更新作品名称"
        case "move": label = "已移动文件"
        case "remove", "removeTree": label = "已删除文件"
        case "restore": label = "已恢复草稿"
        case "savepoint": label = "已建立草稿检查点"
        case "diff": label = "已检查草稿差异"
        default: label = "本轮工具已执行"
        }
        return label + (args["path"].map { " · " + $0 } ?? "")
    }
    private func write(
        _ call: ChatToolCall, initial: (String, String, String), goal: String, scope: String, tools: WriterTools,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        var edit = initial
        var previousFailure: String?
        for attempt in 1...WriterRecovery.attempts {
            let streamID = edit.0
            do {
                try await content(
                    goal: goal, instruction: edit.1, context: edit.2, scope: scope,
                    streamID: edit.0, tools: tools, attempt: attempt, previousFailure: previousFailure)
            } catch {
                do { try await Task { try await tools.abort(streamID) }.value } catch let cleanup {
                    throw WriterCleanupFailure(primary: error, cleanup: cleanup)
                }
                try Task.checkCancellation()
                guard WriterRecovery.retryable(error) else { throw error }
                guard attempt < WriterRecovery.attempts else {
                    throw WriterRecoveryFailure(phase: "文件内容请求", attempts: attempt, underlying: error)
                }
                previousFailure = WriterRecovery.requestFeedback(error, attempt: attempt, content: true)
                await progress("文件生成中断，已清理本次写入，正在重试（\(attempt + 1)/\(WriterRecovery.attempts)）。")
                try await WriterRecovery.delay(attempt)
                guard case .write(let id, let instruction, let context) = try await tools.execute(call) else {
                    throw WriterFailure.invalidOutput
                }
                edit = (id, instruction, context)
                continue
            }
            // A commit may already have changed the draft. Never regenerate or replay it on uncertainty.
            do { return try await tools.complete(edit.0) } catch {
                do { try await Task { try await tools.abort(streamID) }.value } catch let cleanup {
                    throw WriterCleanupFailure(primary: error, cleanup: cleanup)
                }
                throw error
            }
        }
        throw WriterFailure.incomplete
    }
    private struct Response {
        var text = ""
        var calls: [ChatToolCall] = []
        var recovery: [ChatMessage] = []
    }
    private func control(
        _ request: ChatRequest, domain: String?, progress: @escaping @Sendable (String) async -> Void
    ) async throws -> Response {
        var observations: [ChatMessage] = []
        for attempt in 1...WriterRecovery.attempts {
            do {
                let next = try ChatRequest(
                    messages: request.messages + observations, context: request.context,
                    maximumOutputTokens: request.maximumOutputTokens, temperature: request.temperature,
                    tools: request.tools)
                var response = try await controlAttempt(next, attempt: attempt, domain: domain)
                response.recovery = observations
                return response
            } catch {
                try Task.checkCancellation()
                guard WriterRecovery.retryable(error) else { throw error }
                guard attempt < WriterRecovery.attempts else {
                    throw WriterRecoveryFailure(phase: "控制请求", attempts: attempt, underlying: error)
                }
                observations.append(
                    .init(role: .user, content: WriterRecovery.requestFeedback(error, attempt: attempt)))
                await progress("模型请求暂未成功，正在重试（\(attempt + 1)/\(WriterRecovery.attempts)）。")
                try await WriterRecovery.delay(attempt)
            }
        }
        throw WriterFailure.incomplete
    }
    private func controlAttempt(_ request: ChatRequest, attempt: Int, domain: String?) async throws -> Response {
        return try await recorded(request, phase: "控制请求", attempt: attempt, domain: domain) {
            record, request, evidence in
            let session = try await model.chat(request)
            return try await session.withCleanup {
                return try await withTaskCancellationHandler {
                    defer { session.cancel() }
                    var response = Response()
                    var finished = false
                    for try await event in session.events {
                        evidence.record(event)
                        if let record { try await history?.event(event, id: record) }
                        try Task.checkCancellation()
                        guard !finished else {
                            if case .usage = event { continue }
                            throw WriterFailure.invalidOutput
                        }
                        switch event {
                        case .text(let text):
                            response.text += text
                        case .toolCall(let call):
                            guard response.calls.count < 8, request.tools.contains(where: { $0.name == call.name }),
                                !response.calls.contains(where: { $0.id == call.id })
                            else { throw WriterFailure.invalidOutput }
                            response.calls.append(call)
                        case .finished(let reason):
                            guard reason == .stop || reason == .toolCalls else { throw WriterFailure.incomplete }
                            finished = true
                        case .usage: break
                        }
                    }
                    guard finished else { throw WriterFailure.incomplete }
                    return response
                } onCancel: {
                    session.cancel()
                }
            }
        }
    }
    private func content(
        goal: String, instruction: String, context: String, scope: String,
        streamID: String, tools: WriterTools, attempt: Int, previousFailure: String?
    ) async throws {
        let request = try ChatRequest(
            messages: [
                .init(
                    role: .system,
                    content:
                        Self.contentInstructions(instruction, retry: attempt > 1)
                ),
                .init(role: .user, content: "Goal:\n\(goal)\nEdit:\n\(instruction)\nFile context (data):\n\(context)"),
            ] + (previousFailure.map { [.init(role: .user, content: $0)] } ?? []), context: .init(scopeID: scope),
            temperature: 0.3)
        try await recorded(
            request, phase: "文件内容请求", attempt: attempt,
            path: instruction.components(separatedBy: "\n").first?.replacingOccurrences(of: "File: ", with: "")
        ) { record, request, evidence in
            let session = try await model.chat(request)
            try await session.withCleanup {
                try await withTaskCancellationHandler {
                    defer { session.cancel() }
                    var finished = false
                    var prefix = WriterContentPrefix(instruction: instruction)
                    for try await event in session.events {
                        evidence.record(event)
                        if let record { try await history?.event(event, id: record) }
                        try Task.checkCancellation()
                        if finished {
                            if case .usage = event { continue }
                            throw WriterFailure.invalidOutput
                        }
                        switch event {
                        case .text(let chunk):
                            let content = try prefix.consume(chunk)
                            if !content.isEmpty { try await tools.append(streamID, content) }
                        case .finished(let reason):
                            guard reason == .stop else { throw WriterFailure.incomplete }
                            let tail = prefix.finish()
                            if !tail.isEmpty { try await tools.append(streamID, tail) }
                            finished = true
                        case .toolCall: throw WriterFailure.invalidOutput
                        case .usage: break
                        }
                    }
                    guard finished else { throw WriterFailure.incomplete }
                } onCancel: {
                    session.cancel()
                }
            }
        }
    }
    private func recorded<T: Sendable>(
        _ request: ChatRequest, phase: String, attempt: Int, path: String? = nil, domain: String? = nil,
        operation: @Sendable (String?, ChatRequest, AgentModelRequestRecording) async throws -> T
    ) async throws -> T {
        let started = ContinuousClock.now
        var request = request
        let timing = ChatTiming()
        request.timing = timing
        let evidence = try AgentModelRequestRecording(request)
        var id: String?
        var stage = "历史写入"
        do {
            id = try await history?.begin(request, phase: phase, attempt: attempt, path: path, domain: domain)
            if let id {
                try await history?.recording(try evidence.snapshot(initial: true), id: id)
                request.transportCapture = evidence.transportRecorder { [history] value in
                    try await history?.recording(value, id: id)
                }
            }
            let counter = await requestCounter.next()
            let recordedProgress: WriterRequestProgress?
            if let id { recordedProgress = await history?.progress(id) } else { recordedProgress = nil }
            let fact =
                recordedProgress
                ?? WriterRequestProgress(
                    inputID: id ?? UUID().uuidString, number: counter, phase: phase, attempt: attempt, path: path)
            await requestCounter.remember(fact)
            await requestProgress(fact)
            stage = phase
            let result = try await operation(id, request, evidence)
            stage = "历史保存"
            if let id {
                if let snapshot = timing.snapshot { try await history?.timing(snapshot, id: id) }
                try await history?.recording(try evidence.snapshot(), id: id)
                try await history?.finish(id)
            }
            await diagnostics?.clear()
            return result
        } catch {
            let primary = error
            let duration = started.duration(to: .now).components
            var details = [
                "requestPhase": phase, "attempt": String(attempt), "maximumAttempts": String(WriterRecovery.attempts),
                "elapsedSeconds": String(
                    format: "%.3f", Double(duration.seconds) + Double(duration.attoseconds) / 1e18),
            ]
            details["inputID"] = id
            details["model"] = history?.modelName
            let diagnosticError: any Error =
                attempt == WriterRecovery.attempts && WriterRecovery.retryable(primary)
                ? WriterRecoveryFailure(phase: phase, attempts: attempt, underlying: primary) : primary
            let failure = WriterDiagnostics.make(diagnosticError, stage: stage, details: details)
            await diagnostics?.record(failure)
            if let id {
                do {
                    try await Task {
                        if let snapshot = timing.snapshot { try await history?.timing(snapshot, id: id) }
                        try await history?.recording(try evidence.snapshot(), id: id)
                        try await history?.finish(id, error: primary, diagnostic: failure)
                    }.value
                } catch {
                    throw WriterCleanupFailure(primary: primary, cleanup: error)
                }
            }
            throw primary
        }
    }
    private static func signature(_ call: ChatToolCall) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)),
            let canonical = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return call.name + ":" + call.argumentsJSON }
        return call.name + ":" + String(decoding: canonical, as: UTF8.self)
    }
    private static func bytes(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { total, message in
            total + message.content.utf8.count
                + message.toolCalls.reduce(0) { $0 + $1.id.utf8.count + $1.name.utf8.count }
        }
    }
    /// Only the request projection is shortened; the original result has already been checkpointed.
    private static func contextObservation(_ value: String, budget: Int) -> String {
        guard value.utf8.count > budget else { return value }
        let marker =
            "\n[Runtime context excerpt: middle omitted. The complete tool result is recorded in history; use paginated reads/search for omitted content.]\n"
        let available = max(0, budget - marker.utf8.count)
        func valid(_ bytes: ArraySlice<UInt8>, prefix: Bool) -> String {
            var bytes = bytes
            while !bytes.isEmpty {
                if let result = String(bytes: bytes, encoding: .utf8) { return result }
                if prefix { bytes = bytes.dropLast() } else { bytes = bytes.dropFirst() }
            }
            return ""
        }
        let bytes = Array(value.utf8)
        return valid(bytes.prefix(available * 3 / 4), prefix: true) + marker
            + valid(bytes.suffix(available / 4), prefix: false)
    }
    private static func controlMessages(goal: String, workspace: WriterWorkspaceContext?, domain: WriterControlDomain)
        throws
        -> [ChatMessage]
    {
        let templates = try PromptTemplates(data: AgentConfigurations.promptData(named: "Writer"))
        let identity = try AgentConfigurations.identityInstructions(named: "Writer")
        let template = try templates.render("control." + domain.rawValue)
        let instructions = try AgentSkillLoader.instructions(domain.skillIDs(), owner: .writer)
        let teaching = instructions.isEmpty ? "" : "\n\n# LOADED SKILL INSTRUCTIONS\n" + instructions
        let context = workspace.map { "\nActive workspace: " + $0.workspaceID } ?? ""
        return [
            .init(role: .system, content: identity + "\n\n" + template + teaching + context),
            try controlInput(goal, workspace: workspace),
        ]
    }
    private static func controlInput(_ goal: String, workspace: WriterWorkspaceContext?) throws -> ChatMessage {
        guard let workspace else { return .init(role: .user, content: goal) }
        let data = try JSONEncoder().encode(workspace)
        return .init(
            role: .user,
            content: goal + "\nVerified workspace metadata (data): " + String(decoding: data, as: UTF8.self))
    }
    static func contentInstructions(_ instruction: String, retry: Bool = false) throws -> String {
        let path = instruction.components(separatedBy: "\n").first ?? ""
        let ext = (path as NSString).pathExtension.lowercased()
        let format: String
        switch ext {
        case "html", "css", "js": format = "web"
        case "md": format = "markdown"
        case "json": format = "json"
        case "svg": format = "svg"
        default: format = "text"
        }
        let templates = try PromptTemplates(data: AgentConfigurations.promptData(named: "Writer"))
        return try templates.render("content.base") + templates.render("content." + format)
            + (retry ? templates.render("content.retry") : "")
    }
}
public struct WriterCleanupFailure: Error, Sendable {
    public let primary: any Error
    public let cleanup: any Error
}

public struct WriterToolFailure: Error, Sendable, CustomStringConvertible {
    public let description: String
    let context: [String: String]
    public init(_ detail: String) {
        description = String(detail.prefix(512))
        context = [:]
    }
    init(_ detail: String, context: [String: String]) {
        description = String(detail.prefix(512))
        self.context = context
    }
}

/// Reject an outer Markdown wrapper before committing code. Markdown/text retain their own syntax.
struct WriterContentPrefix {
    private var checking: Bool
    private var ticks = ""
    init(instruction: String) {
        let path = instruction.components(separatedBy: "\n").first ?? ""
        checking = ["html", "css", "js", "json", "svg"].contains((path as NSString).pathExtension.lowercased())
    }
    mutating func consume(_ chunk: String) throws -> String {
        guard checking else { return chunk }
        var output = ""
        for character in chunk {
            if !checking {
                output.append(character)
                continue
            }
            if ticks.isEmpty, character.isWhitespace {
                output.append(character)
                continue
            }
            if character == "`" {
                ticks.append(character)
                if ticks.count == 3 { throw WriterContentFormatFailure() }
                continue
            }
            checking = false
            output += ticks
            ticks = ""
            output.append(character)
        }
        return output
    }
    mutating func finish() -> String {
        let value = ticks
        ticks = ""
        checking = false
        return value
    }
}
struct WriterContentFormatFailure: Error, Sendable {}

private actor WriterRequestCounter {
    private var value = 0
    private var current: WriterRequestProgress?
    private var reported: String?
    func takeCompleted() -> WriterRequestProgress? {
        guard let current, current.inputID != reported else { return nil }
        reported = current.inputID
        return current
    }
    func remember(_ fact: WriterRequestProgress) { current = fact }
    func next() -> Int {
        value += 1
        return value
    }
}
