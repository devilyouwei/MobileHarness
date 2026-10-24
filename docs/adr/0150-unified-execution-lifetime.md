# ADR 0150 — Unified capabilities: shared execution lifetime

Date: 2026-10-06. Status: first stage implemented.

## Decision

Adopt the [unified executable capability design](../../MobileHarness/README.md#ownership-and-compilation) before implementation. One capability may be exposed as ActionCall and ToolCall; protocol registration does not override its execution/resource policy. Actions will own query and effect implementations.

Start with CooperativeExecution in ActionRuntime: a generic handler/deadline race, structured cancellation and joined cleanup, retaining the handler result after a winning timeout. ActionDeadline and ToolExecutor adapt outcomes to existing report/response policies. No queues, workers, permissions or business classification are added.

ToolRuntime remains separately compiled but depends only on ActionRuntime. This is an explicit staged exception to ADR0098's dependency-free ToolRuntime; ActionRuntime remains a leaf. Gateway still imports execution contracts only. Existing JSON v5 and separate definitions/catalogs remain current during this stage.

## Status and next stages

✅ Shared lifetime is consumed by both executors; Action timeout report precedence and Tool completion/returning behavior are preserved. Ownership remains held through cleanup.
❌ Unified definitions/results, dual-protocol registration, versioned configuration bindings, scheduled ToolCall semantics and migration of Tool domains into Actions remain pending. Configuration cannot silently gain permissions. Uncooperative handlers cannot be forcibly terminated.

Validation belongs to Validation-History; no physical acceptance is implied.

Follow-up: [ADR0151](0151-consolidated-capability-sources.md) moves all execution/domain sources into Actions; ToolRuntime becomes a re-export-only compatibility target.
