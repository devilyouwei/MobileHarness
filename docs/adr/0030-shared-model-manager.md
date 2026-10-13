# 0030 — Shared Model Manager

> Historical scope: Historical assembly stage. [ADR 0034](0034-modelkit-default-assembly.md) moved production provider registration to ModelKitDefaults; current management contracts live in [ModelKit/Management](../../MobileHarness/ModelKit/Support/Management/README.md).

Status: implemented; sustained device acceptance pending.

## Decision

App owns one ModelKitRuntime.ModelManager. It owns registrations, optional manifests, factory tasks, stable providers and their ModelContexts. Typed get returns capability protocols. ModelKit stays independent of concrete adapters, AgentCore and UI; factories in App construct adapters with the supplied context.

Each context owns one typed ModelResource. Adapters acquire a lease for the actual backend lifetime and release only after cleanup; a returned streaming session is not completion. Register cancellation callbacks so shutdown can interrupt active sessions. System services use lightweight resource tokens without claiming ownership of OS model weights.

ModelManifest is immutable artifact metadata and validation. Catalog lookup is part of the manager. CapabilityResolver maps roles without another registry/cache. No private adapter ModelManager, separate ModelRegistry or ProviderRegistry remains.

## Behavior

- Default get ensures load; deferred get creates only a stable capability instance.
- Concurrent construction and loading coalesce within explicit bounds; failed construction/load can retry.
- Cancelled callers do not cancel shared loads. Waiting cancellation is observed after shared work settles; loaders/factories must be finite and cooperative.
- Explicit unload gates resources and waits for leases. Old handles remain valid and can load again.
- Shutdown closes admission, cancels active work and waits for backend cleanup; it is terminal.
- End-of-turn, XML errors and voice stop do not decide model residency.
- Initial policy retains resources until explicit unload/shutdown. Automatic eviction and measured global-memory budgets are not implemented.

Detailed API, bounds, algorithms and diagrams: [ModelKitRuntime](../../MobileHarness/ModelKit/Support/Management/README.md).
