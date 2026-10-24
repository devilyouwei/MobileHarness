# ADR 0149 — Signal origin and returning Tool feedback

Date: 2026-10-06. Status: implemented; validation recorded in Validation-History.

## Decision

Update the authoritative [Signal feedback contract](../../MobileHarness/README.md#ui-requests-and-business-execution) before changing runtime code. Add SignalOrigin.external/agent/runtime to the existing InputMetadata, preserving one envelope and payload contracts. The default is External; constructors alone grant no routing authority.

Public send/publish admit only External origin and reject execution feedback payloads. Identity-bound OutputGateway messaging constructs Agent origin. The runtime constructs Runtime feedback and validates captured ownership; returning Tool delivery is module-internal rather than ordinary public send. An Agent replaced under the same ID/session cannot receive the old execution's result.

OutputEnvelope retains original input metadata. Returning Tools preserve causal root, parent inputID, turn, sequence and one extra hop with a fresh10-second admission deadline. Execution may outlive original input admission. Delivery rejection, expired/stale scope or hop exhaustion remains distinct from actual Tool success/failure, without replay or a new queue. Completion-only Tools keep existing outcome semantics.

## Consequences

✅ External/Agent/Runtime origin is explicit and Gateway-enforced. Agent schemas/configuration remain JSON v5 with input version1. Tests use bounded injected fixtures for provenance, causal continuity, replacement ownership and retained effects.
❌ Legacy host runtime.event controls retain External origin until typed-control migration. Original Action/activity causal roots, durable feedback, remote authentication, generic request/reply and LLM continuation remain separate work. Action/activity owner fencing is retained; this stage does not claim complete causal unification.
