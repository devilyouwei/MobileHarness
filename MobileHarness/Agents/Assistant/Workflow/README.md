# Assistant workflow

Decision/ReACT orchestration, model request construction, history projection, generation transport, Task communication and lifecycle.

The worker executes a model's `listening` write within the generating round. Entering quiet updates the listening coordinator and retires the initiating input's speech handles. The control result and history terminal state use ordinary round settlement. See [listening input](../Input/README.md#listening-and-quiet).

| File | Responsibility |
| --- | --- |
| [AssistantChatWorker.swift](AssistantChatWorker.swift) | Worker actor, conversation orchestration and bounded post-interruption speech wait. |
| [AssistantChatContext.swift](AssistantChatContext.swift) | AssistantChatState, workflow control intent, transactional history context and recovery/compression. |
| [AssistantChatLifecycle.swift](AssistantChatLifecycle.swift) | Session lifecycle and Task/Skill initialization. |
| [AssistantChatGeneration.swift](AssistantChatGeneration.swift) | Generation per input: language selection, rounds, execution, completion and batch finish. |
| [AssistantGenerationTransport.swift](AssistantGenerationTransport.swift) | Ordered output reader, bounded native execution slots and per-round seals. |
| [AssistantHistoryProjection.swift](AssistantHistoryProjection.swift) | Durable history reconstruction and private request selection. |
| [AssistantChatTaskCommunication.swift](AssistantChatTaskCommunication.swift) | Directed task communication: receiving tasks and reports, `task.send` delivery and rejection. |
| [AssistantChatPeerEvents.swift](AssistantChatPeerEvents.swift) | Peer events, completion facts and the notice queue. |
| [AssistantSessionControl.swift](AssistantSessionControl.swift) | Runtime cleanup/close message and typed decoding. |

The speech interruption barrier is installed before cancellation crosses an asynchronous boundary. After cleanup, a one-shot probe waits 1.28 s (40 VAD windows of 512 samples at 16 kHz) for possible onset; speech already confirmed during cancellation bypasses it. The barrier then waits for all tracked final admissions, empty results or failures, and releases immediately after the last settlement. A candidate still pending when the probe elapses must confirm or clear. All facts come from the subscribed `perception.speech.activity.v1` Signal (see [Input](Input/README.md#speech-activity-and-listening-signals)) and are capture-generation fenced; unavailable capture or ten seconds of stalled observation is reported as failure, not silence. Pause, stop and session closure retire the wait identity, so a late cleanup return cannot recreate it. Cancelled-round settlement remains admissible while ordinary same-session dispatch waits. See [input and decision](../README.md#full-duplex-input-and-decision) for batching and speech lifecycle interfaces.
