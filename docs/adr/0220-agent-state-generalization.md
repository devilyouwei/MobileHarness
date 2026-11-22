# ADR 0220 — Agent state generalization and removal of the Task concept

## Decision

Task is no longer a concept or a control family. An Agent owns a table of string state variables declared in its `Agent.json` `states` field, either typed (Swift-checked, usable in logic and Triggers) or semantic (natural language placed in the prompt). The model writes only its own variables by short name through `state.set`, `state.clear` and `state.get`; the system places them in the Agent's namespace. A read-only variable rejects model writes (the model continues through ReACT, the prompt does not mention access). Free semantic variables are bounded (32) and evict the oldest instead of failing. Every write records a time, and one fixed-template function renders the variables, ordered by time with natural-language absolute time, into an independent system block before the user message. State is memory-only and not user-editable.

`task` is a preset semantic variable with the first Trigger: changing it opens or closes a goal interval and compresses the history it covered. Skills are loaded and unloaded with `skill.load` and `skill.unload` and are unrelated to goals; `useStates` only decides which variables are injected alongside a Skill. Messaging is the independent `send` control. Same-named Skills, actions and states merge so each appears once in the prompt. Declared writes without a return value throw on failure; `state.get` always returns a value.

## Rationale and consequences

Task was one state among many (quiet, mood, speaking style); treating it specially duplicated control code and coupled Skills to goals. A generic variable table with declared Triggers lets new states and later alarms or timers reuse one path. `assistant_tasks` stays, but only for the `task` goal interval; other state changes are logged in memory and shown in the read-only State tab of the runtime log, including rejected writes. Writer still treats each `send` as one task delegation internally and is optimized separately.

Alarm and timed Triggers are reserved only. This supersedes the Task terminology of [ADR 0028](0028-inter-agent-communication.md) for Agent control; its communication contracts stay. Design and implementation record: [State generalization](../requirements/technical/State-Generalization-Task-Removal.md).
