# Assistant state

State exposure only, without orchestration.

The execution log presents `agents.assistant.listening` as JSON with the Boolean listening value and `wakeCondition`. After waking, the condition reads as null.

| File | Responsibility |
| --- | --- |
| [AssistantChatStatus.swift](AssistantChatStatus.swift) | Lifecycle, reply activity, resident context, visible variables and effective capabilities. |
