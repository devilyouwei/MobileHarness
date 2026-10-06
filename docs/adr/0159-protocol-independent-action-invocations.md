# ADR0159 — Protocol-independent Action invocations

Accepted: 2026-10-06. Supersedes ADR0158 typed native authoring adapters; the active design was corrected before implementation.

One @Action metadata signature emits canonical ActionHandler/ActionCompletionHandler factories. Business entries and injected endpoints use ActionInvocation/ActionExecutionContext exclusively. ToolInvocation/ToolExecutionContext and the reverse native invocation view are retired. Native ToolRequest/result contracts remain runtime transport adapters; they normalize once before shared execution.

Registration, model transport/parsing, scheduling and feedback may differ; implementation signatures do not. Native ToolCall can be direct or scheduled. Text ActionCall retains Channel/wait behavior. Existing permissions, resource constraints, cleanup and feedback policy remain explicit and unchanged.

✅ Implemented: one macro/handler/invocation/context, shared ActionArguments, explicit native normalization and canonical endpoint bindings. Boundary and regression checks separate implementation, registration, model transport, admission and feedback responsibilities.

❌ Broader Signal/business route migration and physical/model acceptance remain separate work.

ADR0160 further separates pure ActionFunction metadata from host-created ActionBinding protocol/scheduling/feedback policy; the shared invocation decision remains current.
