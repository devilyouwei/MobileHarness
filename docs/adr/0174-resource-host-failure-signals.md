# ADR0174 — Resource host failure Signals

Accepted: 2026-10-07. Design updated before code.

Recoverable resource admission/dispatch failures become model.resource.hostFailure/1 external Signals from app.resources. The immutable payload carries original requestID, admission/dispatch phase, operation/preference/refresh scope and a nonblank message bounded to 2048 UTF-8 bytes; refresh requires a positive generation. The envelope starts fresh work with rootID equal to its new ID and parentID equal to the original requestID. This does not impersonate native ToolResult or human intent.

The root transport retires and joins the original request before attempting diagnostic admission. ResourceManagement chooses an existing registered error function; preference uses execution, never text-derived validation reasons. One returning UI call finishes diagnostic handling. The original caller still receives its original failure, marked presented only after acknowledgment; secondary failures remain in the error chain. Acknowledged presentation remains marked presented even if later feedback/control transport fails.

Admission requires an already-started, open runtime, available request capacity and an empty single diagnostic slot (no queue). Another in-flight error presentation also suppresses diagnostics. Startup/cancellation/capacity failure and unavailable infrastructure retain explicit local fallback. Once error presentation has been attempted, do not diagnose its failure recursively. No operation retry, model-callable grant, new directory, foundational dependency or native Action algorithm changes.

✅ Implemented in the domain schema, ResourceManagement, root transport and source admission. Focused regressions cover causal/source validation, UTF-8 bounds, dispatch without effects, malformed preference feedback, overlapping binding admission and missing/failed diagnostic presentation. Validation-History.md records checks and acceptance limits.
