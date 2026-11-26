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

Interrupt admission installs the dispatch barrier and records the start of 64 actual VAD windows. ExecutionSession joins the old generation and receives the cleanup terminal through Gateway while speech intake keeps running. The worker retains existing onset and ASR as well as onsets starting through window 64. Later onsets use ordinary admission and stay outside the released batch. Cleanup may delay dispatch while the onset boundary stays fixed. A replacement capture restarts the count. See [post-interruption wait](../Input/README.md#post-interruption-wait).

At interrupt admission, the worker freezes the current request's reply text at the first speech unit without native completion. The snapshot carries the latest decoded and emitted reply Action and its round identity. Generation and execution cleanup join before this snapshot updates the matching history request. The dispatch barrier remains closed until the write succeeds. A fully parsed and played reply or a request without an emitted `speak` keeps its original response. History reconstruction adds the `replyInterruptedDuringPlayback` marker to the trimmed reply in model context.
