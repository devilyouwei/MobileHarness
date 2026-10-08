# ADR0180 — Memory and Photographer business service organization

Accepted: 2026-10-08. Design precedes code.

## Decision

Rename ConversationMemory to Memory, including directory, actor, JSON resource and live AgentID. Keep Photographer's identity: photography, video, movement and interaction during a shoot are its intended business role, with pose tracking currently implemented. No ApplicationControl migration is included.

Use one canonical role directory with matching actor/configuration basenames and lowerCamelCase live identity. Actor shells own lifecycle, input validation, serial state isolation, bounded output and status; internal co-located components own focused business workflows/algorithms. No new helper directory, target, base Agent inheritance or runtime alias is introduced.

## Implementation scope

✅ MemoryAgent delegates existing history intent/result sequencing to MemoryHistoryWorkflow; title inference stays in ConversationTitleGenerator. PhotographerAgent delegates target/filter/motion policy to PhotographerTrackingPolicy, retaining session/freshness/control availability checks and committing target state only after successful output admission. Update packaging, host transport, authorization guards and tests as one migration.

History function paths and history.intent/1 payload remain stable. MemoryHistoryIntent is the typed history-domain API, not a generic long-term-memory protocol. Queues, cancellation, correlated completion, output failure isolation, tracking thresholds/rates/limits and native motion algorithms are unchanged. Persisted raw historical records are not rewritten.

## Outstanding scope

❌ Structured short/long-term memory CRUD, semantic recall/consolidation/forgetting, photography/video/camera movement planning and shoot-time interaction need separately designed contracts and implementations. The reorganization must not expose stub capabilities or claim these are implemented.

## Validation

✅ ./scripts/check.sh passed, including 591 IntegrationTests, 51 AppWorkflowTests, boundary checks, six Python tests, formatting and metadata lint. Relevant regressions cover title failure chains, history cancellation/correlation and Photographer freshness/throttle/overflow/admission commit. Added canonical role identity/mismatch and Memory overflow isolation tests.

✅ Generic iOS device build (unsigned) and byte-for-byte packaging verification passed with seven configurations, including Memory/memory. All 209 current source Mermaid diagrams parse; local documentation links resolve.

❌ Required ./scripts/build-ios.sh stopped at MobileHarnessSimulator because external CoreAIShared could not resolve CoreAI for arm64/x86_64 Simulator; subsequent schemes were not reached. No installation, native UI, real-model or physical movement acceptance was performed. See Validation-History for evidence.
