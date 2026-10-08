# ADR0168 — Agent-owned resource preference transactions

Accepted: 2026-10-07. Implemented; design revised before code.

Restore/save intents select pure System.ModelResources functions. Actions owns the persisted schema, legacy speech-flag migration, endpoint validation via a narrow injected SDK adapter, installed-model prerequisites and revision-checked document writes. Storage remains an independent bounded document SDK. The4096-byte store and existing endpoint/unrestricted-network migration are preserved.

ResourceManagement receives bounded2048-byte canonical preference JSON as returning feedback, validates it and selects configureSpeech through OutputGateway. It resolves only after returning binding feedback crosses InputGateway. One preference/configuration request rejects overlap; independent resource commands retain their32-request bound. Host transport owns at most one current worker per request and joins it before accepting the next call, captures the preference result and retires request state on dispatch/feedback failure. Output capacity64 remains sufficient for32 bounded two-call requests.

The MainActor Settings facade owns view-value conversion, cached successful results and32 coalesced restore waiters. It injects restore/save operations and preserves durable-before-download, fresh refresh/removal reconciliation and page-independent admission. Saving invalidates view cache before submission; failure cannot present an old cached preference as current. A committed preference is retained on later binding failure and explicit restore retries it. App owns native lifecycle/SDK adaptation and localized selection-notice mapping. No automatic retry or fallback.

Actions gains an explicit Storage target dependency; existing directories and targets are reused. Agent/configuration JSON grants remain internal-only. UI installed-group indicators and localized failure presentation remain staged until registered resource-state effects; status polling/provider selection/model-callable exposure are not covered here.

## Validation

✅ scripts/check.sh passes:534 IntegrationTests and35 AppWorkflowTests. Added targeted regressions for malformed preference feedback/retirement and coalesced page-independent restore also pass. Device-target build passes;7 packaged Agent configs match source;193 current Mermaid diagrams parse after replacing superseded Settings diagrams.

❌ scripts/build-ios.sh remains blocked by the external CoreAIShared simulator dependency missing CoreAI. Native resource/model switching and background restoration need physical-device acceptance.

Error handling uses the last confirmed view flags instead of calling effectful restore. After preference failure, status polling skips preference reconciliation; explicit restore/save may retry. Failed status reconciliation remains visible and does not silently retry a binding.
