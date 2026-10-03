# Routing — Output Execution Paths

Purpose: classify output without performing its side effects. ActionCalls use Action scheduling; ToolCalls use tool execution.

- ✅ ExecutionRouter returns action, scheduling, tool, finish, cancel or observe routes.
- ✅ AgentOutput.actionCall carries ActionCall; natural text is mapped to resolved Actions inside the Agent.
- ✅ ActionDispatcher admits ActionCalls into ChannelScheduler; ToolCalls enter Tools/Runtime directly.
- ✅ Runtime control messages map to completion, cancellation and observation routes.
- ❌ Separate typed runtime lifecycle events.

```mermaid
flowchart LR
    Output[AgentOutput] --> Router[ExecutionRouter]
    Router -->|actionCall / scheduling| Actions[ActionDispatcher]
    Router -->|toolCall| Tools[ToolDispatcher]
    Router -->|control| Lifecycle[Finish / cancel / observe]
```

Update this README with changes to names, routing rules and ✅/❌ status.

✅ ExecutionRouter recognizes generic agent.finished and agent.error runtime controls as finish/cancel barriers, preserving legacy assistant names.


✅ ExecutionRouter has a scheduling route for typed wait begin/end directives, sent through ActionDispatcher. It never parses XML, assigns aliases or executes a barrier itself. ❌ Native Tools remain outside the wait tree.

✅ Call rejection routing raises a typed failure outside Action cancellation handling; no invocation is executed. ❌ No automatic retry.
