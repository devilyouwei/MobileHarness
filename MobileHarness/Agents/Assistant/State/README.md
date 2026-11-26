# Assistant state

State exposure only, without orchestration.

The execution log presents `agents.assistant.listening` as JSON with the Boolean listening value and `wakeCondition`. After waking, the condition reads as null.

| File | Responsibility |
| --- | --- |
| [AssistantStateBindings.swift](AssistantStateBindings.swift) | Business-only exact-path State adaptation. |
| [AssistantChatStatus.swift](AssistantChatStatus.swift) | Signal preparation, status, resident context, effective capabilities and decision metadata. |
