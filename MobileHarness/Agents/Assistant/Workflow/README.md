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

After keyword cleanup resolves, the worker logs its outcome together with the observation's model identity, detection interval and cumulative inference duration. Cleanup time is outside the detection interval. See [keyword input](../Input/README.md#流式关键词快停).

At interrupt admission, the worker captures the current request's emitted source-bearing Actions and their original order. It accepts matching successful terminal feedback until execution cleanup is confirmed. After generation and execution cleanup join, the worker persists the completed Actions' source fragments in submission order and keeps the dispatch barrier closed until the write succeeds. Model history and queued native tool attachments render the settled text with the `replyInterruptedMarker` template from Assistant's localized prompt resources.
