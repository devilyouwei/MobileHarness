# ADR0164 — Typed Assistant host control

Accepted: 2026-10-07. Implemented; owning designs updated before code.

Replace the production assistant.cancel string with AssistantControl.cancelSession in assistant.control/1. Domain content and schema live in Agents/Communication; AgentCore remains generic. App sends an external host Signal through InputGateway with source runtime, session identity, explicit causal root and a fresh 10-second deadline. This source label does not grant runtime-feedback authority.

Assistant removes runtime.event from its input grants and rejects arbitrary strings. Typed controls validate contract/content, version, host provenance and freshness before queue mutation. Cancellation bypasses full/paused inboxes, removes only the selected session inputs and joins that session's active worker. It does not roll back accepted effects, erase durable history, invoke a model or change App's capture/audio/output cleanup order. Other sessions remain intact. No new directory, queue, subscription or model permission is introduced.

✅ Final check.sh passed, including514 integration tests,37 workflow tests, independent target tests, boundary checks, formatting and metadata. Six targeted regressions passed, including seven invalid-control cases. All191 MobileHarness Mermaid diagrams parse and local documentation paths resolve. The unsigned generic iOS device build passed and all six packaged Agent configurations verified.

❌ Required build-ios.sh stops in its first simulator scheme because external CoreAIShared cannot resolve CoreAI; subsequent schemes were not attempted. No new physical-device interaction acceptance was performed.

Remaining lifecycle/capability facts, archive/title policy, settings/device entry points and bounded model continuation remain separate stages.
