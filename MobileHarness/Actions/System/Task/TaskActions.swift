import FunctionContracts

extension SystemActions {
    @Action(
        domain: "Agent", module: "Task", title: "sendMessage",
        doc:
            "Send user input to background work.",
        parameters: [
            .init("taskID", description: "Actual background task ID"),
            .init("text", description: "Relevant user answer or correction"),
            .init(
                "executor",
                description: "Owning Agent ID, e.g. writer; runtime resolves delegation and pending question"),
        ], timeout: .seconds(30))
    public static func sendMessage(_ input: any FunctionInput, capability: any TaskControlCapability) async throws
        -> ActionCompletion
    {
        .value(try await capability.controlTask("sendMessage", arguments: input.call.parameters, invocation: input))
    }
    @Action(
        domain: "Agent", module: "Task", title: "loadSkills",
        doc: "Atomically load Skills; returns committed state for the following request.",
        parameters: [
            .init(
                "skills", type: .string, required: true, description: "JSON array of Skill IDs; atomic update",
                constraints: "Unique nonempty IDs, at most 16")
        ], completion: "Committed task/Skill transition", timeout: .seconds(5))
    public static func loadSkills(_ input: any FunctionInput, capability: any TaskControlCapability) async throws
        -> ActionCompletion
    {
        .value(try await capability.controlTask("loadSkills", arguments: input.call.parameters, invocation: input))
    }
    @Action(
        domain: "Agent", module: "Task", title: "releaseSkills",
        doc: "Atomically release non-base Skills; returns committed state for the following request.",
        parameters: [
            .init(
                "skills", type: .string, required: true, description: "JSON array of Skill IDs; atomic update",
                constraints: "Unique nonempty IDs, at most 16")
        ], completion: "Committed task/Skill transition", timeout: .seconds(5))
    public static func releaseSkills(_ input: any FunctionInput, capability: any TaskControlCapability) async throws
        -> ActionCompletion
    {
        .value(try await capability.controlTask("releaseSkills", arguments: input.call.parameters, invocation: input))
    }
    @Action(
        domain: "Agent", module: "Task", title: "startTask",
        doc:
            "Start foreground here or delegate background; acceptance preserves foreground work.",
        parameters: [
            .init(
                "goal", type: .string, required: true,
                description: "Goal; Writer: one line, <=1024 UTF-8 bytes, no code", constraints: "Bounded text"),
            .init(
                "skills", type: .string, required: false,
                description: "JSON Skill IDs; omit for Writer",
                constraints: "Bounded text"),
            .init(
                "execution", type: .string, required: false, description: "foreground (default) or background",
                constraints: "Bounded text"),
            .init(
                "executor", type: .string, required: false,
                description: "Background executor ID: writer",
                constraints: "Bounded text"),
            .init("taskID", required: false, description: "Writer only: actual saved task to resume"),
            .init(
                "replaceCurrent", type: .boolean, required: false,
                description: "Writer only: authorized replacement after cleanup",
                values: ["true", "false"]),
            .init("title", required: false, description: "Writer work title"),
            .init("entry", required: false, description: "Writer entry: index.html/document.md/document.txt"),
            .init(
                "businessContract", type: .string, required: false,
                description: "Non-Writer background only: registered contract",
                constraints: "Bounded text"),
            .init(
                "payload", type: .string, required: false,
                description: "Non-Writer background only: contract JSON",
                constraints: "Bounded text"),
        ], completion: "Foreground committed, or background accepted", timeout: .seconds(30))
    public static func startTask(_ input: any FunctionInput, capability: any TaskControlCapability) async throws
        -> ActionCompletion
    {
        .value(try await capability.controlTask("startTask", arguments: input.call.parameters, invocation: input))
    }
    @Action(
        domain: "Agent", module: "Task", title: "finishTask",
        doc:
            "Finish foreground only; background completion belongs to its executor. continueDecision requires a remaining new goal.",
        parameters: [
            .init(
                "summary", type: .string, required: true, description: "summary", constraints: "Nonempty bounded text"),
            .init(
                "continueDecision", type: .boolean, required: false,
                description:
                    "Continue only to a different goal still requested by this user input; omit after ordinary completion",
                constraints: "true or false; default false", values: ["true", "false"]),
        ], completion: "Committed task/Skill transition", timeout: .seconds(5))
    public static func finishTask(_ input: any FunctionInput, capability: any TaskControlCapability) async throws
        -> ActionCompletion
    {
        .value(try await capability.controlTask("finishTask", arguments: input.call.parameters, invocation: input))
    }
    @Action(
        domain: "Agent", module: "Task", title: "cancelTask",
        doc:
            "Cancel foreground; taskID requests background cleanup. Await its terminal.",
        parameters: [
            .init(
                "reason", type: .string, required: true, description: "User cancellation reason",
                constraints: "Nonempty bounded text"),
            .init(
                "taskID", required: false,
                description: "Agent-local background task_N; omit for current foreground Task"),
            .init(
                "executor", required: false, description: "Required with background taskID; owning Agent, e.g. writer"),
        ], completion: "Foreground cancelled, or background cancellation delivered", timeout: .seconds(30))
    public static func cancelTask(_ input: any FunctionInput, capability: any TaskControlCapability) async throws
        -> ActionCompletion
    {
        .value(try await capability.controlTask("cancelTask", arguments: input.call.parameters, invocation: input))
    }
}
