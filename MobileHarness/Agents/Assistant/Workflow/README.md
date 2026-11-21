# Assistant workflow

Decision/ReACT orchestration, model request construction, history projection, generation transport, Task communication and lifecycle.

| File | Responsibility |
| --- | --- |
| [AssistantChatWorker.swift](AssistantChatWorker.swift) | Worker actor and conversation orchestration. |
| [AssistantChatContext.swift](AssistantChatContext.swift) | AssistantChatState, workflow control intent, transactional history context and recovery/compression. |
| [AssistantChatLifecycle.swift](AssistantChatLifecycle.swift) | Session lifecycle and Task/Skill initialization. |
| [AssistantChatGeneration.swift](AssistantChatGeneration.swift) | Generation per input: language selection, rounds, execution, completion and batch finish. |
| [AssistantGenerationTransport.swift](AssistantGenerationTransport.swift) | Ordered output reader, bounded native execution slots and per-round seals. |
| [AssistantHistoryProjection.swift](AssistantHistoryProjection.swift) | Durable history reconstruction and private request selection. |
| [AssistantChatTaskCommunication.swift](AssistantChatTaskCommunication.swift) | Directed task communication: receiving tasks and reports, `task.send` delivery and rejection. |
| [AssistantChatPeerEvents.swift](AssistantChatPeerEvents.swift) | Peer events, completion facts and the notice queue. |
| [AssistantSessionControl.swift](AssistantSessionControl.swift) | Runtime cleanup/close message and typed decoding. |
