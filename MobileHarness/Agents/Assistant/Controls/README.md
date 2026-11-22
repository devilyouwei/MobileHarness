# Assistant controls

Control library and execution. Declarations load from [Resources/Agents/Assistant/Controls](../../../Resources/Agents/Assistant/Controls) (`Controls*.json` declarations, `Controls*.md` usage guide); see [Agent controls](../../Support/Core/Capability/README.md#agent-controls) for the shared mechanism.

| File | Responsibility |
| --- | --- |
| [AssistantControls.swift](AssistantControls.swift) | Library loading and validation, `AgentControlOperation`, fixed registrations and the usage guide. |
| [AssistantControlExecution.swift](AssistantControlExecution.swift) | `executeControl`, `control` gating, the state/Skill/send entries, the `task` trigger, `setHostState` and the late-bound `AssistantControlLink`. |

The late-bound link also forwards speech publication failures to the Assistant's utterance wait owner; it does not deliver speech text.

## Control library

| Alias | Destination | Completion | Effect |
| --- | --- | --- | --- |
| `state.set(name,value[,note])` | self | void; failure throws | Writes one of the Agent's own variables. |
| `state.clear(name[,note])` | self | void; failure throws | Clears one own variable; clearing an unset one is a no-op. |
| `state.get(path)` | self | value; failure throws | Short name reads an own variable; a dotted path reads any state through the Container context resolver. |
| `skill.load(skills)` / `skill.unload(skills)` | self | value | Atomic Skill transitions; they occupy the whole response and take effect on the next request. |
| `send(agent_id,text)` | peer | void; failure throws | Relays a message to a peer Agent; delivery confirms receipt only. |

A thrown error becomes a `controlFailed` tool result and a value result is business output, so both continue the decision through the existing `requiresReasoning` rule; a void success does not. Cancellation propagates unchanged.

## State writes

The model supplies only a short name; the variable always lives in the Assistant's own table, so Container State and other Agents are unreachable. Declared variables come from `states` in Agent.json (see [Resources/Agents](../../../Resources/Agents/README.md)); every other lowercase name is a free note. The model cannot write a `readOnly` variable, and nothing about access appears in the prompt: the write is rejected with `readOnly` and the decision continues. The host writes through `setHostState` (source `host`), which ignores `access` but accepts only declared names and never the `task` variable.

`task` is the variable bound to the `task` trigger. Its value is owned by the foreground goal record, not by the variable table, so exactly one copy exists:

- Setting it with no active goal opens a goal record (SQLite row first, then the private context transaction, which also assigns the history interval). A failed binding closes the row as failed.
- Clearing it requires `note`. In full-duplex or host mode the goal is completed and its history compressed at once; otherwise it is marked finishing and settles when its decision joins.
- Setting it while a goal is active requires `note` (the old goal's summary) and is only available in the immediate modes above; otherwise it throws `replacementUnavailable`. The old goal closes first, then the new one opens; a failure in between leaves no goal and is reported.
- Skills are unrelated to the goal: no control loads or releases a Skill because of `task`.
