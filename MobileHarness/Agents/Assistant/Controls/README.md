# Assistant controls

Control library and execution. Declarations load from [Resources/Agents/Assistant/Controls](../../../Resources/Agents/Assistant/Controls) (`Controls*.json` declarations, `Controls*.md` usage guide); see [Agent controls](../../Support/Core/Capability/README.md#agent-controls) for the shared mechanism.

| File | Responsibility |
| --- | --- |
| [AssistantControls.swift](AssistantControls.swift) | Library loading and validation, `AgentControlOperation`, fixed registrations and the usage guide. |
| [AssistantControlExecution.swift](AssistantControlExecution.swift) | `executeControl`, `controlTask` gating, Task/Skill transactions and the late-bound `AssistantControlLink`. |
