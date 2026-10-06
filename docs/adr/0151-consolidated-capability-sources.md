# ADR 0151 — Consolidated executable capability sources

Date: 2026-10-06. Status: implemented source consolidation.

## Decision

Update the [adopted design](../../MobileHarness/Agent-Driven-App.md#unified-executable-capabilities--adopted-design) before moving sources. Consolidate directories before unifying definitions: Actions owns all concrete query/effect domains and ActionRuntime owns both protocol runtimes. Preserve existing JSON v5, API names and behavior.

Tools and ToolRuntime compile only re-export shims under Actions/Compatibility, depending respectively on Actions and ActionRuntime. No duplicate source compilation or reverse dependency is allowed. Actions acquires StorageChat for the moved History domain; only History may import that journal.

## Consequences

✅ Original Tools directory is removed. UI protocol entries share the existing UI domain; Camera, Robot, History and System move as cohesive domains with updated ownership READMEs. Gateway retains scheduling/admission/resource/feedback policy. Both existing runtime definition families compile once under ActionRuntime.
❌ Unified definitions/results, dual-protocol adapters and consumer-import migration remain pending. Source consolidation does not authorize another protocol, convert a scheduled capability into a direct call, or establish physical acceptance.

Validation belongs to Validation-History.

Follow-up: [ADR0152](0152-business-domain-capability-classification.md) consolidates canonical domain namespaces and catalogs, including UI display functions and NexArm tracking.
