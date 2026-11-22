# Assistant input

Everything entering the Assistant: input admission, batch text, the independent interruption Decision and interruption contracts. Input prompt resources are under [Resources/Agents/Assistant/Input](../../Resources/Agents/Assistant/Input).

| File | Responsibility |
| --- | --- |
| [AssistantChatInput.swift](AssistantChatInput.swift) | Input admission, text handling, prepared batches, interruption speech-wait gating, queue drain and reply-turn start. |
| [AssistantInputBatch.swift](AssistantInputBatch.swift) | Trusted source timeline, batch text, source-line markers and input prompt access. |
| [AssistantInputDecision.swift](AssistantInputDecision.swift) | Frozen current-turn context, interruption question, latest-wins classification and targeted signal submission. |
| [AssistantInterrupt.swift](AssistantInterrupt.swift) | Public interruption target, signal and result contracts. |

## Decision scheduling and cleanup

AssistantDecisionQueue retains at most 32 unsettled jobs, including the current job; overflow rejects classification without removing ordinary input. New admission cancels the current classification and replaces the waiting inference candidate. The serial settlement worker records superseded jobs with `signalStatus = superseded`, no boolean and no model failure; only the newest candidate is inferred. A result already submitted to the interruption entry is not retroactively revoked. Closing a session removes its jobs and cancels its current classification; pause/stop cancels and joins the queue worker.

AssistantInputDecision owns at most one actual inference worker and one waiting attempt per local/cloud channel. New attempts cancel the previous worker and retire its result, but cannot start until that worker exits its complete ModelKit cleanup. Waiting consumes the new attempt's existing deadline; expiry explicitly reports timeout, never overlapping native calls or switching providers. Attempt IDs fence timeout, cancellation and completion so stale callbacks cannot affect successors. Model maintenance/switching and root shutdown join the retained inference worker. CoreAI cancellation remains cooperative: this scheduling cannot forcibly terminate a stuck native call.
