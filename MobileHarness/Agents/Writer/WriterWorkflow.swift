import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import UI

public enum WriterFailure: String, Error, Sendable {
    case unsupportedModel, invalidOutput, incomplete, capacity, unavailable, cancelled
}

enum WriterInboxIntent: String { case followUp, stop, newWork }

/// Host ports bind authenticated request identity. Writer may select its work, never its execution owner.
public struct WriterTools: Sendable {
    public let definitions: [ChatToolDefinition]
    let library: [ChatToolDefinition]?
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
        library: [ChatToolDefinition]? = nil
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
    let entryExists: Bool
    let entryEmpty: Bool
    let presentationStatus: String

    var domain: String { "workspace:" + workspaceID }
}

enum WriterMilestone: Sendable {
    case draftUpdated, recovering, renderIssue
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

    func registry() throws -> CapabilityRegistry {
        try AgentConfigurations.registry(AgentSkillLoader.bindings(skillIDs(), owner: .writer), owner: .writer)
    }

    func definitions(_ registry: CapabilityRegistry) throws -> [ChatToolDefinition] {
        try registry.tools.map { tool in
            guard let definition = tool.definition else { throw WriterFailure.invalidOutput }
            return try ChatToolDefinition(declaration: JSONEncoder().encode(definition))
        }
    }

    func toolDefinitions(_ tools: WriterTools) -> [ChatToolDefinition] {
        switch self {
        case .library: tools.library ?? []
        case .editing: tools.definitions
        }
    }
}
enum WriterLocalTools {
    static let declarations: [ActionDeclaration] = [
        tool(
            "ask", "Pause for essential user information.",
            [.init("question", description: "Nonempty question for the user, up to 2048 UTF-8 bytes.")]),
        tool(
            "finish", "End the delegation in a separate tool round. Report actual results.",
            [
                .init("summary", description: "Brief factual completion summary."),
                .init(
                    "outcome", required: false,
                    description:
                        "Use artifact for publishing or library operations, explanation for a completed answer, declined for infeasible work, or cancelled when the user asks you to stop. Cancelled preserves the draft without publishing.",
                    values: ["artifact", "explanation", "declined", "cancelled"]),
            ]),
        tool(
            "enter", "Enter a saved workspace for editing or switch to another saved workspace. Call alone.",
            [
                .init(
                    "workspaceID",
                    description: "Exact workspace_N known from the user, current context, or workspace.search.")
            ]),
        tool(
            "create", "Create a new workspace, initialize an empty entry file and enter it for editing. Call alone.",
            [
                .init("title", description: "Nonempty display title in the user’s language."),
                .init(
                    "entry",
                    description:
                        "Workspace-relative file path ending in .html, .md or .txt, such as flowchart.html or docs/flowchart.md. Pass the path only. Write source content with edit."
                ),
            ]),
    ]

    static func contains(_ path: String) -> Bool {
        declarations.contains { $0.path.description == path }
    }

    private static func tool(_ name: String, _ doc: String, _ parameters: [ActionParameter]) -> ActionDeclaration {
        .init(path: .init(domain: "Agent", module: "Writer", function: name), doc: doc, parameters: parameters)
    }
}

public struct WriterNeedsInput: Error, Sendable { public let question: String }
public enum WriterToolOutcome: Sendable {
    case waiting(String)
    case observation(String)
    case entered(WriterWorkspaceContext, evidence: String)
    case visual(String, ChatImage)
    case write(ArtifactEditPreparation)
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
    static func inboxIntent(
        _ text: String, goal: String, question: String?, model: any ChatCapability, language: String = "en"
    ) async throws -> WriterInboxIntent {
        let data = try JSONEncoder().encode(["goal": goal, "question": question ?? "", "message": text])
        let instructions = try AgentPrompts.shared.load("Agents/Writer/Prompts.json", language: language)
            .render("inboxIntent")
        let request = try ChatRequest(
            messages: [
                .init(role: .system, content: instructions),
                .init(role: .user, content: String(decoding: data, as: UTF8.self)),
            ], maximumOutputTokens: 24, temperature: 0)
        let session = try await model.chat(request)
        return try await session.withCleanup {
            try await withTaskCancellationHandler {
                var response = ""
                var finished = false
                for try await event in session.events {
                    try Task.checkCancellation()
                    switch event {
                    case .text(let text) where !finished:
                        response += text
                        guard response.utf8.count <= 96 else { throw WriterFailure.invalidOutput }
                    case .finished(.stop) where !finished: finished = true
                    case .usage: break
                    default: throw WriterFailure.invalidOutput
                    }
                }
                guard finished,
                    let intent = WriterInboxIntent(rawValue: response.trimmingCharacters(in: .whitespacesAndNewlines))
                else { throw WriterFailure.invalidOutput }
                return intent
            } onCancel: {
                session.cancel()
            }
        }
    }

    private let model: any ChatCapability
    private let history: WriterHistory?
    private let diagnostics: WriterDiagnosticCapture?
    private let requestCounter = WriterRequestCounter()
    private let requestProgress: @Sendable (WriterRequestProgress) async -> Void
    private let roundCompleted: @Sendable (WriterRequestProgress?, String) async -> Void
    private let milestone: @Sendable (WriterMilestone) async -> Void
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
        milestone = { _ in }
    }
    init(
        model: any ChatCapability, history: WriterHistory?, diagnostics: WriterDiagnosticCapture,
        requestProgress: @escaping @Sendable (WriterRequestProgress) async -> Void = { _ in },
        roundCompleted: @escaping @Sendable (WriterRequestProgress?, String) async -> Void = { _, _ in },
        milestone: @escaping @Sendable (WriterMilestone) async -> Void = { _ in }
    ) {
        self.requestProgress = requestProgress
        self.roundCompleted = roundCompleted
        self.model = model
        self.history = history
        self.diagnostics = diagnostics
        self.milestone = milestone
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
        let restored =
            try await history?.restoredContext(
                domain: domain, availableTools: Set(controlDomain.toolDefinitions(tools).map(\.name))) ?? []
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
                currentGoal += "\n" + (try AgentPrompts.text("Writer/Prompts", "additionalRequirement", ["text": text]))
                guard currentGoal.utf8.count <= 48_000 else { throw WriterFailure.capacity }
                messages[1] = try Self.controlInput(currentGoal, workspace: workspace)
                messages.append(
                    .init(
                        role: .user,
                        content: try AgentPrompts.text("Writer/Prompts", "additionalRequirement", ["text": text])))
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
                || response.calls.contains { ["finish", "workspace.enter", "workspace.create"].contains($0.name) }
            let late = terminalCandidate ? try await revisions() : []
            if !late.isEmpty {
                for call in response.calls {
                    let notice = try AgentPrompts.text("Writer/Prompts", "lateRequirement")
                    try await history?.toolOutcome(call.id, output: notice)
                    messages.append(.init(role: .tool, content: notice, toolCallID: call.id))
                }
                for text in late {
                    guard text.utf8.count <= 4096 else { throw WriterFailure.capacity }
                    currentGoal +=
                        "\n" + (try AgentPrompts.text("Writer/Prompts", "additionalRequirement", ["text": text]))
                    guard currentGoal.utf8.count <= 48_000 else { throw WriterFailure.capacity }
                    messages[1] = try Self.controlInput(currentGoal, workspace: workspace)
                    messages.append(
                        .init(
                            role: .user,
                            content: try AgentPrompts.text("Writer/Prompts", "additionalRequirement", ["text": text])))
                }
                await completeRound(
                    Self.copy.text("New instructions received. The previous actions were skipped."), tools: tools)
                continue
            }
            guard !response.calls.isEmpty else {
                recoveryFailures += 1
                if recoveryFailures >= WriterRecovery.attempts {
                    throw WriterRecoveryFailure(
                        phase: "Assignment completion", attempts: recoveryFailures, underlying: WriterFailure.incomplete
                    )
                }
                messages.append(
                    .init(
                        role: .user,
                        content: try AgentPrompts.text("Writer/Prompts", "finishRequired")))
                await completeRound(Self.copy.text("Waiting for the model to finish the assignment."), tools: tools)
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
                        ["finish", "ask", "workspace.enter", "workspace.create"].contains($0.name)
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
                                    try AgentPrompts.text("Writer/Prompts", "separateRound"),
                                toolCallID: call.id))
                    }
                    if recoveryFailures >= WriterRecovery.attempts {
                        throw WriterRecoveryFailure(
                            phase: "Tool batch correction", attempts: recoveryFailures,
                            underlying: WriterFailure.invalidOutput)
                    }
                    await completeRound(
                        Self.copy.text("The tools did not run. Preparing corrected arguments."), tools: tools)
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
                                content: try WriterRecovery.feedback(
                                    error, attempt: recoveryFailures, repeated: repeated),
                                toolCallID: call.id))
                        if recoveryFailures >= WriterRecovery.attempts {
                            throw WriterRecoveryFailure(
                                phase: "Tool correction", attempts: recoveryFailures, underlying: error)
                        }
                        steps.append(Self.copy.text("The tool failed. Preparing a correction."))
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
                        let switching = workspace != nil
                        workspace = selected
                        domain = selected.domain
                        controlDomain = .editing
                        messages = try Self.controlMessages(
                            goal: currentGoal, workspace: selected, domain: controlDomain)
                        if switching {
                            messages.append(
                                .init(
                                    role: .user,
                                    content: try AgentPrompts.text("Writer/Prompts", "switchResult") + evidence))
                        }
                        failedCalls.removeAll()
                        recoveryFailures = 0
                        previousSignature = nil
                        repetitions = 0
                        await completeRound(Self.step(call, observation: evidence), tools: tools)
                        continue controlLoop
                    case .observation(let value):
                        observation = value
                        if ["replace", "move", "removeTree", "remove", "restore"].contains(call.name) {
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
                    case .write(let edit):
                        await completeRound(
                            (steps + [Self.copy.text("The file is ready for editing. Generating content next.")])
                                .joined(separator: " · "), tools: tools)
                        steps.removeAll()
                        observation = try await write(
                            call, initial: edit, goal: currentGoal, scope: scope,
                            tools: tools, progress: progress)
                        generatedContent = true
                        failedCalls.removeAll()
                        recoveryFailures = 0
                    }
                    if ["render", "workspace.search"].contains(call.name) {
                        // Rendering changes publication preconditions, even without changing source bytes.
                        // Do not reset the recovery budget or unblock unrelated failed effects.
                        failedCalls = failedCalls.filter { _, error in
                            guard let failure = error as? WriterToolFailure else { return true }
                            if call.name == "workspace.search" {
                                return failure.context["condition"] != "workspaceSearchRequired"
                            }
                            return failure.context["command"] != "finish"
                                || !failure.description.contains("renderRequired")
                        }
                    }
                    try await history?.toolOutcome(call.id, output: observation)
                    if generatedContent || ["replace", "move", "removeTree", "remove", "restore"].contains(call.name) {
                        await milestone(.draftUpdated)
                    } else if call.name == "render", observation.contains("\"errors\"") {
                        await milestone(.renderIssue)
                    }
                    pending.remove(call.id)
                    let observationBudget = max(
                        0,
                        (48_000 - Self.bytes(Array(messages.prefix(2)))
                            - response.text.utf8.count - 2048) / max(1, response.calls.count))
                    messages.append(
                        .init(
                            role: .tool,
                            content: try Self.contextObservation(observation, budget: observationBudget),
                            toolCallID: call.id))
                    steps.append(Self.step(call, observation: observation))
                    if generatedContent {
                        await completeRound(steps.joined(separator: " · "), tools: tools)
                        steps.removeAll()
                    }
                    repetitions = signature == previousSignature ? repetitions + 1 : 1
                    previousSignature = signature
                    if [3, 5, 8].contains(repetitions) {
                        reminders.append(
                            try AgentPrompts.text(
                                "Writer/Prompts", "repeatedCall", ["count": String(repetitions)])
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
                                try AgentPrompts.text("Writer/Prompts", "batchStopped"),
                                context: ["executed": "false"])
                        try await Task { try await history?.toolOutcome(call.id, output: nil, error: cause) }.value
                    } catch { failure = WriterCleanupFailure(primary: failure, cleanup: error) }
                }
                throw failure
            }
            await completeRound(steps.joined(separator: " · "), tools: tools)
            messages += reminders.map { ChatMessage(role: .user, content: $0) }
            if let image = latestImage, await model.supportsImages {
                messages = messages.map {
                    .init(role: $0.role, content: $0.content, toolCalls: $0.toolCalls, toolCallID: $0.toolCallID)
                }
                messages.append(
                    .init(
                        role: .user, content: try AgentPrompts.text("Writer/Prompts", "screenshot"),
                        images: [image]))
            }
        }
    }
    private func completeRound(_ text: String, tools: WriterTools) async {
        guard !Task.isCancelled, let fact = await requestCounter.takeCompleted() else { return }
        await tools.refresh()
        guard !Task.isCancelled else { return }
        await roundCompleted(fact, text.isEmpty ? Self.copy.text("This round has finished.") : text)
    }
    private static var copy: AppLanguage { AppLanguage(preferredLanguage: AgentPrompts.language) }

    private static func step(_ call: ChatToolCall, observation: String) -> String {
        let args = (try? JSONDecoder().decode([String: String].self, from: Data(call.argumentsJSON.utf8))) ?? [:]
        let label: String
        switch call.name {
        case "edit", "replace": label = "File updated"
        case "read": label = "File read"
        case "list": label = "Directory listed"
        case "workspace.search": label = "Project library searched"
        case "workspace.create": label = "Workspace created and opened"
        case "workspace.enter": label = "Existing workspace opened"
        case "workspace.open": label = "Project presentation handled"
        case "workspace.delete": label = "Project deleted"
        case "search": label = "Files searched"
        case "render":
            if observation.contains("\"unavailable\"") || observation.contains("\"deferred\"") {
                label = "The page is hidden. The draft was kept."
            } else if observation.contains("\"errors\"") {
                label = "Render check found an issue. Preparing a fix."
            } else {
                label = "Page rendering checked"
            }
        case "rename": label = "Project renamed"
        case "move": label = "File moved"
        case "remove", "removeTree": label = "File deleted"
        case "restore": label = "Draft restored"
        case "savepoint": label = "Draft checkpoint saved"
        case "diff": label = "Draft changes checked"
        default: label = "Tool executed"
        }
        return copy.text(label) + (args["path"].map { " · " + $0 } ?? "")
    }
    private func write(
        _ call: ChatToolCall, initial: ArtifactEditPreparation, goal: String, scope: String, tools: WriterTools,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        var edit = initial
        var previousFailure: String?
        for attempt in 1...WriterRecovery.attempts {
            let streamID = edit.streamID
            do {
                try await content(
                    goal: goal, edit: edit, scope: scope,
                    tools: tools, attempt: attempt, previousFailure: previousFailure)
            } catch {
                do { try await Task { try await tools.abort(streamID) }.value } catch let cleanup {
                    throw WriterCleanupFailure(primary: error, cleanup: cleanup)
                }
                try Task.checkCancellation()
                guard WriterRecovery.retryable(error) else { throw error }
                guard attempt < WriterRecovery.attempts else {
                    throw WriterRecoveryFailure(phase: "File content request", attempts: attempt, underlying: error)
                }
                previousFailure = try WriterRecovery.requestFeedback(error, attempt: attempt, content: true)
                await milestone(.recovering)
                await progress(
                    AppLanguage(preferredLanguage: AgentPrompts.language).format(
                        "File generation stopped. Partial changes were cleared. Retrying (%@/%@).",
                        String(attempt + 1), String(WriterRecovery.attempts)))
                try await WriterRecovery.delay(attempt)
                guard case .write(let nextEdit) = try await tools.execute(call) else {
                    throw WriterFailure.invalidOutput
                }
                edit = nextEdit
                continue
            }
            // A commit may already have changed the draft. Never regenerate or replay it on uncertainty.
            do { return try await tools.complete(streamID) } catch {
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
                    throw WriterRecoveryFailure(phase: "Control request", attempts: attempt, underlying: error)
                }
                observations.append(
                    .init(role: .user, content: try WriterRecovery.requestFeedback(error, attempt: attempt)))
                await milestone(.recovering)
                await progress(
                    AppLanguage(preferredLanguage: AgentPrompts.language).format(
                        "Model request failed. Retrying (%@/%@).", String(attempt + 1), String(WriterRecovery.attempts))
                )
                try await WriterRecovery.delay(attempt)
            }
        }
        throw WriterFailure.incomplete
    }
    private func controlAttempt(_ request: ChatRequest, attempt: Int, domain: String?) async throws -> Response {
        return try await recorded(request, phase: "Control request", attempt: attempt, domain: domain) {
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
        goal: String, edit: ArtifactEditPreparation, scope: String,
        tools: WriterTools, attempt: Int, previousFailure: String?
    ) async throws {
        let streamID = edit.streamID
        let request = try ChatRequest(
            messages: [
                .init(
                    role: .system,
                    content: Self.contentInstructions(edit.path, retry: attempt > 1)
                ),
                .init(
                    role: .user,
                    content: try AgentPrompts.text(
                        "Writer/ContentPrompts", "request",
                        [
                            "goal": goal, "path": edit.path, "instruction": edit.instruction,
                            "context": Self.contentContext(edit),
                        ])),
            ] + (previousFailure.map { [.init(role: .user, content: $0)] } ?? []), context: .init(scopeID: scope),
            temperature: 0.3)
        try await recorded(request, phase: "File content request", attempt: attempt, path: edit.path) {
            record, request, evidence in
            let session = try await model.chat(request)
            try await session.withCleanup {
                try await withTaskCancellationHandler {
                    defer { session.cancel() }
                    var finished = false
                    var prefix = WriterContentPrefix(path: edit.path)
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
        var stage = "History write"
        do {
            id = try await history?.begin(request, phase: phase, attempt: attempt, path: path, domain: domain)
            if let id {
                request.onDispatch = { [history] in try await history?.dispatched(id) }
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
            stage = "History save"
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
    private static func contextObservation(_ value: String, budget: Int) throws -> String {
        guard value.utf8.count > budget else { return value }
        let marker =
            try AgentPrompts.text("Writer/Prompts", "excerpt")
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
        let templates = try AgentPrompts.roleTemplates(named: "Writer")
        let identity = try AgentConfigurations.identityInstructions(named: "Writer")
        let language = try templates.render(
            "outputLanguage", variables: ["default": AgentPrompts.defaultOutputLanguage])
        let template = try templates.render("control." + domain.rawValue)
        let instructions = try AgentSkillLoader.instructions(domain.skillIDs(), owner: .writer)
        let teaching =
            instructions.isEmpty
            ? "" : "\n\n" + (try AgentPrompts.skillCatalog().render("loadedHeading")) + "\n" + instructions
        let context =
            try workspace.map { try AgentPrompts.text("Writer/Prompts", "activeWorkspace") + $0.workspaceID }
            ?? ""
        return [
            .init(role: .system, content: identity + "\n\n" + language + "\n\n" + template + teaching + context),
            try controlInput(goal, workspace: workspace),
        ]
    }
    private static func controlInput(_ goal: String, workspace: WriterWorkspaceContext?) throws -> ChatMessage {
        guard let workspace else { return .init(role: .user, content: goal) }
        let data = try JSONEncoder().encode(workspace)
        return .init(
            role: .user,
            content: goal + (try AgentPrompts.text("Writer/Prompts", "workspaceMetadata"))
                + String(decoding: data, as: UTF8.self))
    }
    private static func contentContext(_ edit: ArtifactEditPreparation) throws -> String {
        let templates = try AgentPrompts.shared.load("Agents/Writer/ContentPrompts.json")
        let target: String
        if let selection = edit.selection {
            target = try templates.render(
                "selection",
                variables: [
                    "start": String(selection.start), "end": String(selection.end),
                    "leadingNewline": String(selection.selected.hasPrefix("\n")),
                    "trailingNewline": String(selection.selected.hasSuffix("\n")),
                    "before": selection.before, "selected": selection.selected, "after": selection.after,
                ])
        } else {
            target = try templates.render("newFile", variables: ["files": edit.projectFiles.joined(separator: ", ")])
        }
        let related = try edit.relatedFiles.map { file in
            try templates.render(
                "relatedFile",
                variables: [
                    "path": file.path, "version": String(file.version), "start": String(file.start),
                    "end": String(file.end), "text": file.text,
                ])
        }
        return target + related.joined()
    }
    static func contentInstructions(_ path: String, retry: Bool = false) throws -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let format: String
        switch ext {
        case "html", "css", "js": format = "web"
        case "md": format = "markdown"
        case "json": format = "json"
        case "svg": format = "svg"
        default: format = "text"
        }
        let templates = try AgentPrompts.shared.load("Agents/Writer/ContentPrompts.json")
        return try templates.render("instructions") + " " + templates.render("format." + format)
            + " "
            + AgentPrompts.text("Writer/Prompts", "outputLanguage", ["default": AgentPrompts.defaultOutputLanguage])
            + (retry ? templates.render("retry") : "")
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
    init(path: String) {
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
