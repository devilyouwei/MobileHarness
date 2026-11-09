import FunctionContracts

extension SystemActions {
    @Action(
        domain: "Agent", module: "Task", title: "sendMessage",
        doc: "Send input to the foreground task or to a target Agent.",
        parameters: [
            .init("text", description: "Relevant input or correction"),
            .init("agent_id", required: false, description: "Target Agent; omit for foreground"),
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
            "Start a foreground goal owned by the calling Agent. Peer alternative to delegateTask, never its prerequisite.",
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
    @Action(
        domain: "Agent", module: "Task", title: "cancelTask",
        doc: "Cancel foreground or send cancellation to a target Agent.",
        parameters: [
            .init("reason", description: "Cancellation reason"),
            .init("agent_id", required: false, description: "Target Agent; omit for foreground"),
        ], completion: "Cancellation accepted", timeout: .seconds(30))
    public static func cancelTask(_ input: any FunctionInput, capability: any TaskControlCapability) async throws
        -> ActionCompletion
    {
        try await capability.controlTask("task.cancel", arguments: input.call.parameters, invocation: input)
    }
    @Action(
        domain: "Agent", module: "Task", title: "delegateTask",
        doc:
            "Directly delegate to a target from the available Agent directory. Peer alternative to startTask; no foreground prerequisite.",
        parameters: [
            .init("agent_id", description: "Target Agent ID"),
            .init("description", description: "Task description; no code"),
        ], completion: "Request accepted; not task completion", timeout: .seconds(30))
    public static func delegateTask(_ input: any FunctionInput, capability: any TaskControlCapability) async throws
        -> ActionCompletion
    {
        try await capability.controlTask("task.delegate", arguments: input.call.parameters, invocation: input)
    }
}
