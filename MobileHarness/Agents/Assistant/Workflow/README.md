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

The output reader admits all Tools into one pool of up to 128 concurrent calls and rejects overflow. Each Tool returns as soon as it completes. Round seals join only calls carrying that round ID. Independent calls participate in output-session shutdown and cancellation.

Interrupt admission installs the dispatch barrier and records the start of 64 actual VAD windows. ExecutionSession joins the old generation and receives cleanup settlement from the local execution adapter while speech intake keeps running. The worker retains existing onset and ASR as well as onsets starting through window 64. Later onsets use ordinary admission and stay outside the released batch. Cleanup may delay dispatch while the onset boundary stays fixed. A replacement capture restarts the count. See [post-interruption wait](../Input/README.md#post-interruption-wait).

After keyword cleanup resolves, the worker logs its outcome together with the observation's model identity, detection interval and cumulative inference duration. Cleanup time is outside the detection interval. See [keyword input](../Input/README.md#流式关键词快停).

The worker joins a confirmed keyword decision with the admitted ASR final by capture generation and utterance ID. Either event can arrive first. A final with text receives the decision in its input coordination and the batch preserves it as member evidence. For an empty final the previous reply still carries the result of the interruption.

At interrupt admission, the worker captures the dispatched request's source-bearing Actions and their original order. It accepts matching successful terminal feedback until execution cleanup is confirmed. Keyword and model Decision share the settlement path. After generation and execution cleanup join, the worker persists the completed fragments, original generated text and winning route with the interrupted request, and keeps the dispatch barrier closed until persistence succeeds. Model history, queued native tool attachments and history detail use the `replyInterruptedMarker` template from Assistant's localized prompt resources.
