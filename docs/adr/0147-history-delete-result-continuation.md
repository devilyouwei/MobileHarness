# ADR0147 — History Deletion and Deterministic Result Continuation

Date: 2026-10-06. Status: implemented.

## Decision

Update [Agent-Driven App Architecture](../../MobileHarness/README.md#tasks-model-decisions-and-history) before changing code. Move confirmed archive deletion out of the legacy feature effect into a ConversationMemory intent. The Agent emits internal History.delete(id), accepts only matching runtime Tool feedback and emits UI.showHistory after success. App binds effects and transports outputs; it does not select the next business operation.

Tools.HistoryMutationService validates archive-only identity and invokes the atomic journal transaction; missing/current IDs fail. Assistant model catalog remains read-only. One pending mutation rejects overlap; descriptor/JSON declare tool.result input and code-owned deletion permission requires id. Duplicate/foreign feedback is rejected.

One root request executes at most2 business calls. Failure/cancellation joins execution, clears pending Agent state through InputGateway and drains a bounded non-business acknowledgment through OutputGateway before retry. Cancelled presentation is explicitly retired. Successful persistence survives later cancellation/presentation failure; no automatic deletion retry occurs.

## Consequences

✅ Deterministic result-driven behavior advances without an LLM or voice session. Existing native UI confirmation remains the sole deletion input binding in this stage. No new dependency, store or Agent is created.

❌ Archival/title, resource Agent routing, model-callable mutation and model continuation remain pending. Native confirmation and destructive conversational acceptance are not claimed.

## Validation

✅ Final full check.sh,15 focused tests and unsigned iOS device build passed. ❌ Simulator CoreAI dependency and native confirmation acceptance remain separate; see [dated evidence](../validation/Validation-History.md#2026-10-06--history-deletion-and-deterministic-result-continuation).
