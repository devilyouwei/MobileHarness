# ADR0158 — Unified Action authoring and model transport

Historical stage, superseded by [ADR0159](0159-protocol-independent-action-invocations.md). Accepted: 2026-10-06. Refines ADR0157; the active Agent-Driven-App.md contract was updated before code.

All business entries use @Action, including direct queries/effects. Factory overloads preserve canonical or native typed handler signatures, normalizing both to ActionDefinition. @Tool and its macro branch are removed. Three-level metadata is consistent across both signatures. Existing production availability, resources, deadlines and completion-only/returning feedback remain unchanged; Agent v6 independently grants model exposure.

Actions enter model context as text-callable metadata; native declarations enter ChatRequest.tools. Native events resolve into ToolCall, text action tags into ActionCall, and ordinary text uses explicit Agent policy. Protocol names remain transport vocabulary, not business implementation categories.

✅ The implementation uses one attribute and canonical definition constructors; startup permissions and execution constraints remain independently validated.

❌ General model continuation, remaining Signal migration and physical/model acceptance remain separate work.
