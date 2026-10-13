import FunctionContracts

extension SystemActions {
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
            "Start a new goal and load its Skills; rejects an existing foreground Task until it is closed. Foreground omits background-only fields.",
        parameters: [
            .init("goal", type: .string, required: true, description: "Task goal", constraints: "Bounded text"),
            .init(
                "skills", type: .string, required: false, description: "Optional JSON array of Skill IDs",
                constraints: "Bounded text"),
            .init(
                "execution", type: .string, required: false, description: "foreground (default) or background",
                constraints: "Bounded text"),
            .init(
                "target", type: .string, required: false,
                description: "Background only: required executor Agent ID; omit for foreground",
                constraints: "Bounded text"),
            .init(
                "businessContract", type: .string, required: false,
                description: "Background only: declared business contract; omit for foreground",
                constraints: "Bounded text"),
            .init(
                "payload", type: .string, required: false,
                description: "Background only: business JSON; omit for foreground",
                constraints: "Bounded text"),
        ], completion: "Committed task/Skill transition", timeout: .seconds(5))
    public static func startTask(_ input: any FunctionInput, capability: any TaskControlCapability) async throws
        -> ActionCompletion
    {
        .value(try await capability.controlTask("startTask", arguments: input.call.parameters, invocation: input))
    }
    @Action(
        domain: "Agent", module: "Task", title: "finishTask",
        doc:
            "Close the current Task. Ends this decision by default; continueDecision is only for an explicit remaining new goal. Summary describes the actual outcome.",
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
        doc: "Cancel the active Task after cleanup joins; returns committed state. Completed effects are not undone.",
        parameters: [
            .init("reason", type: .string, required: true, description: "reason", constraints: "Nonempty bounded text")
        ], completion: "Committed task/Skill transition", timeout: .seconds(5))
    public static func cancelTask(_ input: any FunctionInput, capability: any TaskControlCapability) async throws
        -> ActionCompletion
    {
        .value(try await capability.controlTask("cancelTask", arguments: input.call.parameters, invocation: input))
    }
}
