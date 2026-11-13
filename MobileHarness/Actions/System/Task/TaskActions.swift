import FunctionContracts

extension SystemActions {
    @Action(
        domain: "Agent", module: "Task", title: "sendMessage",
        doc: "Relay the user's request, reply or correction to a peer Agent. The receiver decides how to handle it.",
        parameters: [
            .init("agent_id", description: "Target Agent ID"),
            .init("text", description: "User request, reply, correction or stop request"),
        ], timeout: .seconds(30))
    public static func sendMessage(_ input: any FunctionInput, capability: any TaskControlCapability) async throws
        -> ActionCompletion
    {
        try await capability.controlTask("task.send", arguments: input.call.parameters, invocation: input)
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
        try await capability.controlTask("loadSkills", arguments: input.call.parameters, invocation: input)
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
        try await capability.controlTask("releaseSkills", arguments: input.call.parameters, invocation: input)
    }
    @Action(
        domain: "Agent", module: "Task", title: "startTask",
        doc:
            "Start a foreground goal when none is active. End an existing foreground goal before starting another.",
        parameters: [
            .init("description", description: "Foreground task description"),
            .init("skills", required: false, description: "Optional JSON array of initial foreground Skill IDs"),
        ],
        completion: "Foreground task committed", timeout: .seconds(30))
    public static func startTask(_ input: any FunctionInput, capability: any TaskControlCapability) async throws
        -> ActionCompletion
    {
        try await capability.controlTask("task.start", arguments: input.call.parameters, invocation: input)
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
        try await capability.controlTask("task.end", arguments: input.call.parameters, invocation: input)
    }
}
