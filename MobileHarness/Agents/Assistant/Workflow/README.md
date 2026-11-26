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

Interrupt admission installs the dispatch barrier and asks SpeechPerception to observe 64 processed VAD windows of 512 samples, or 2.048 seconds of audio at 16 kHz. The two branches run in parallel. ExecutionSession joins the old generation and receives the session-wide cleanup terminal through Gateway. SpeechPerception confirms the window through `perception.speech.activity.v1`. Existing onset candidates and ASR remain tracked until they settle. Capture recovery begins a fresh count and preserves any confirmed execution cleanup. Assistant keeps queued inputs and reports unconfirmed cleanup or stalled capture. Pause, stop and speech session closure retire the observation identity.
