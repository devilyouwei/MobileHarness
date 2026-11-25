# Writer workflow

Writer's private loop, native tools and recovery.

WriterTools opts the registered workspace read tool into Responses compatibility for integer `line`, `offset` and `limit` values. The adapter emits those values as decimal strings for the existing host tool interface. Actions owns range and path validation. See the [Responses adapter](../../../ModelKit/Language/LLM/OpenAI/README.md).

| File | Responsibility |
| --- | --- |
| [WriterWorkflow.swift](WriterWorkflow.swift) | Task workflow and content instructions. |
| [WriterTools.swift](WriterTools.swift) | Native tool definitions and execution. |
| [WriterRecovery.swift](WriterRecovery.swift) | Recovery of unfinished work. |
