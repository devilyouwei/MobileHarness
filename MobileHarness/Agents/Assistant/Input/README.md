# Assistant input

Everything entering the Assistant: input admission, batch text, the independent interruption Decision and interruption contracts. Input prompt resources are under [Resources/Agents/Assistant/Input](../../../Resources/Agents/Assistant/Input).

| File | Responsibility |
| --- | --- |
| [AssistantChatInput.swift](AssistantChatInput.swift) | Input admission, text handling, prepared batches, queue drain and reply-turn start. |
| [AssistantInputBatch.swift](AssistantInputBatch.swift) | Trusted source timeline, batch text, source-line markers and input prompt access. |
| [AssistantInputDecision.swift](AssistantInputDecision.swift) | Frozen current-turn context, interruption question, bounded classification queue and targeted signal submission. |
| [AssistantInterrupt.swift](AssistantInterrupt.swift) | Public interruption target, signal and result contracts. |
