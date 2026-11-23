# ADR 0221 — Listening mode as one state variable

## Decision

The read-only `quiet` variable is removed. The Assistant owns one typed enum variable, `listening`, with the values `half` (default), `full` and `quiet`. The model may write it, and the host writes it to leave `quiet`. Changing it runs a Trigger: the Trigger names declared in `Agent.json` now resolve to handlers registered by the owning Agent, replacing the single-case `AgentStateTrigger` enum, so each further variable that needs behavior adds a handler rather than another branch in the write path. Model and host writes share one path: validate, run the handler, publish only if it accepted.

`quiet` is a wake mode, not a mute switch. Speech is still recognized, but each sentence goes to an independent judge with a very short prompt and no history instead of the Assistant conversation. The judge asks the system model first and then the Assistant's selected model, and ends `quiet` only on an `exit` answer. Every judgment is appended to the new `listening_dialogs` table.

## Rationale and consequences

Listening style and silence are one concern; two variables would let them disagree. A registry keeps the write path uniform and makes a missing handler a startup error. Keeping the judge out of the conversation avoids spending the main model's context and latency on speech that is not addressed to the Assistant, and failing toward `quiet` keeps the user from being interrupted by a broken judge. `full` is rejected, or reverted to `half` with a report, when the capture cannot cancel echo, so a mode never silently differs from what was requested.

The default `half` is now explicit: a route that can cancel echo no longer enters full duplex on its own, only when `listening` is `full`. Requirement and open items: [Listening mode](../requirements/technical/Listening-Mode-State.md). Extends [ADR 0220](0220-agent-state-generalization.md).
