# ADR0175 — Agent-routed provider model discovery

Accepted: 2026-10-07. Design updated before code.

Migrate Settings model-list discovery first. App privately stages URL/key under a one-use session-bound requestID, sends provider.discovery/1 to ResourceManagement, and the Agent selects System.Provider.discoverModels through OutputGateway. The callable validates input and returns bounded canonical model IDs through correlated feedback. No URL/key crosses the Signal/call/result/error-record boundary. Neutral explicit errors retain configuration, HTTP status, cancellation or unavailable categories; response bodies and arbitrary SDK descriptions are excluded.

Actions owns staging and result policy; App injects SDK execution and adapts form values; the Agent owns call choice and completion. Existing root32 requests/64 outputs apply, discovery allows one returning call. Staging has32 entries and ten-second claim deadlines, rejects overflow, checks session before removal and consumes before SDK execution. Unclaimed entries are discarded on every host exit. Active query ownership belongs to common execution/root transport with60-second cooperative timeout, independent of page display. UI revision cancellation prevents stale presentation without fabricating native cancellation.

Preserve save preparation, persistence/application/rollback and lifecycle barriers. Those transactions and provider UI effects remain later migrations. Discovery does not retry, change binding or add model-callable permission. Reuse existing directories and ResourceManagement, without targets/dependencies.

✅ Implemented in typed communication, ResourceManagement, the canonical function/request staging, grouped registration and App discovery composition. Failure codes cross the query interface separately from the error chain and are localized at the adapter. Synthetic regressions cover routing, secret-free calls/errors, staging constraints, invalid list bounds, one-use behavior and page-independent admission. See Validation-History.md for verification and acceptance limits.
