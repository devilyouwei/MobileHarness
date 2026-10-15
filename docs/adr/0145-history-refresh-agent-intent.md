# ADR0145 — History Refresh Through a Deterministic Agent

Date: 2026-10-06. Status: implemented.

## Decision

Route history page load/refresh as a typed user intent through InputGateway to ConversationMemory. The root owns a separate memory session and lazy Agent lifecycle, independent of voice and models. The Agent selects internal UI.showHistory; OutputGateway validates permission and invokes an explicitly injected completion capability. JSON v5 has an empty model catalog; fixed internal behavior is declared in Swift.

AppHistoryWorkflow temporarily depends on Agents/Gateway/Tools execution contracts for the root transport and thin adapter. UI retains shared records/state only. The host adapter validates source/session and maps a raw journal snapshot into MainActor state; it owns no title, mutation or selection policy.

One in-flight refresh rejects overlap without backlog. The Agent buffers at most eight outputs and explicitly fails overflow. After admission, a joined cancellation-independent reader consumes the already-buffered correlated output, preserving the long-lived stream. Cancellation prevents effects and retains admission until Tool cleanup joins. Completion acknowledges accepted state, not rendering/navigation.

## Consequences

✅ History refresh no longer selects behavior directly in App; both Gateways are exercised without LLM inference. Required host handlers and startup coverage remain explicit. No model/API credential or new storage instance is needed.

❌ Archive/delete/title and preview retain legacy operations. Navigation, Assistant-triggered memory intent, shared model query/presentation payloads and result-driven reasoning remain subsequent stages. This does not claim full conversational control.

## Validation

✅ Six final focused tests, all 484 full-run integration tests and unsigned iOS device build passed. ❌ The existing audio workflow full-run timeout and simulator CoreAI limitation remain; see [dated evidence](../validation/Validation-History.md#2026-10-06--structured-history-refresh-intent).
