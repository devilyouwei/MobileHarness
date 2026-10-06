# ADR 0148 — Unified Signal contract and active architecture ownership

Date: 2026-10-06. Status: design adopted; documentation implemented, runtime migration remains staged.

## Decision

Move the authoritative Agent-Driven App Architecture from docs into [MobileHarness](../../MobileHarness/README.md). It governs an architecture already being implemented; implemented contracts and outstanding routes are labeled separately.

Signal means immutable information admitted to an Agent, including human intent, physical observations, Agent messages and actual execution feedback. AgentInput is the canonical in-process envelope; do not add a duplicate Signal envelope. Keep domain payloads and schema validation outside generic AgentCore. Resolved execution calls remain OutputEnvelope outputs, and their returning feedback becomes input.

The design specifies source/session/call identity, causal context, monotonic timing, schema/version ownership, Gateway admission, completion distinctions and bounded overflow. New typed business intents use registered domain-message contracts; legacy string history events remain until a separate implementation migration. Current version1 contracts and process-local transport do not imply remote codecs, authentication, replay or version migration support.

## Scenario clarification

The active design now includes UI intent, conversation/perception and Agent collaboration flows. Actual results enter InputGateway before an Agent selects further registered effects. DeliveryReport is admission only; model computation is local capability use; domain replies require explicit correlation/lifetime contracts. Rendering does not automatically generate a new Signal. History deletion is implemented, including its documented legacy host failure presentation; model continuation, conversational discovery and generic request/reply remain pending.

Scenario coverage also includes independent physical observations, system/capability events and execution lifecycle. External/Agent/runtime origin is orthogonal to payload meaning. Typed origin APIs remain pending; host lifecycle mechanisms retain immediate cleanup ownership. Human decisions, concurrency, triggers and recovery require scoped contracts, not additional envelope types.

The document now separates common contracts from scenario examples and consolidates implementation gaps, bounds and migration stages at the end. Traditional mobile interaction is retained, with deterministic Agent handling sharing permissions and execution with conversation. This reorganization changes no runtime contract.

## Consequences

✅ Architecture, indexes and referring links use the new source location. Existing Signal structures and runtime behavior are unchanged.
❌ Typed history intents, residual UI/device adapters, control typing and complete entry-point migration require later implementation and validation. Do not infer completed migration from a shared envelope.

Follow-up: [ADR0149](0149-signal-origin-and-tool-feedback.md) implements typed origin admission and owner-fenced returning Tool causal feedback. Remaining Action/activity roots and typed host controls stay separate migration stages.
