# Assistant state

State exposure only, without orchestration.

The execution log's State view presents `agents.assistant.listening` as JSON with `mode` and `wakeCondition`. After leaving quiet, `wakeCondition` reads as null.

| File | Responsibility |
| --- | --- |
| [AssistantStateBindings.swift](AssistantStateBindings.swift) | Business-only exact-path State adaptation. |
| [AssistantChatStatus.swift](AssistantChatStatus.swift) | Signal preparation, status, resident context, effective capabilities and decision metadata. |
