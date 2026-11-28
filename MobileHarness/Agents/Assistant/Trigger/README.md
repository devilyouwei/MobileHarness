# Assistant state triggers

[Controls](../Controls/README.md#state-writes) validates a host or model write and passes its normalized value, previous table value and request context to the shared trigger dispatcher. At worker initialization, [AssistantTriggers.swift](AssistantTriggers.swift) binds handler names and validates the role schema.

| Handler | Condition and effect | Publication |
| --- | --- | --- |
| [ListeningTrigger.swift](ListeningTrigger.swift) | Applies the listening setting to the input coordinator. When the model puts an active listener into quiet mode, the handler cancels speech for the matching initiating input. | Returns `.publish` so Controls commits the variable and wake condition together. |
| [TaskTrigger.swift](TaskTrigger.swift) | Opens, replaces or closes the foreground goal according to the requested value, active record, summary and decision mode. | Returns `.handled` because the goal record owns the value. |

To add a trigger, bind the variable’s `trigger` in the role’s `Agent.json`, implement its condition and effect here, and register the same name in `makeStateTriggers()`. The handler decides whether a write needs an effect. A repeated value can carry a new wake condition. A thrown error propagates to the writer before table publication. The [shared dispatcher](../../Support/Context/AgentStateTriggers.swift) rejects overlapping calls to the same handler.
