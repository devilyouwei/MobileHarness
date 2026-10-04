# Agent communication domains

Purpose: group the application's typed messages, schemas and built-in identities outside AgentCore. Design goals: one coherent catalog, immutable values, explicit validation and no transport workers.

✅ AgentContracts.swift contains concrete AgentID names, PerceptionMessage Codable cases, typed AgentMessage factories/access and the registered speech/vision schema catalog. Core transports generic messages; Gateway receives the catalog through App composition. Existing JSON v5 names, domain payload JSON, byte limits and freshness are preserved.
✅ Synthesis/cancellation are new work with a fresh 10-second deadline; observations inherit the parent deadline and use their registered lifetime (pose 1s, partial transcript 2s, other messages 10s). Content type and declared contract must match; unknown/duplicate schemas reject assembly/admission.
❌ No inbox, model operation, execution handler, request/reply service or retry loop belongs here. Per-Agent processing remains in each actor.

```mermaid
flowchart LR
    Domain[PerceptionMessage and typed factories] --> Envelope[Core AgentMessage]
    Catalog[AgentContracts schema catalog] --> Config[AgentConfiguration validation]
    Catalog --> App[App composition]
    App --> Policy[Core CommunicationPolicy]
    Envelope --> Gateway[OutputGateway / InputGateway]
    Policy --> Gateway
    Gateway --> Receive[Agent receives typed domain content]
```
