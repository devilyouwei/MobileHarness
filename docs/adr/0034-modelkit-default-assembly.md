# ADR 0034: Internal default model assembly

Status: accepted.

ModelKitDefaults owns the project's fixed mapping: chat uses Qwen3.5, recognition uses Nemotron, VAD uses Silero, synthesis uses Apple system voices. Kokoro has an explicit diagnostic ID without a default binding; judgment has no implementation. Simulator chat and recognition are unavailable without substituting providers.

App provides the resource directory to manager and receives capability interfaces through get(.chat) and the corresponding keys. Deferred retrieval preserves first-use loading. App forwards OS memory warnings but does not register model factories or configure backend caches.

Defaults is a separate internal target depending on adapters and ModelKitRuntime. Management imports only ModelKit and owns identity, bindings and lifecycle. Registration validates default bindings before mutation; duplicate or unsupported defaults fail atomically. Explicit and default retrieval use the same cache. Missing defaults are errors; no automatic fallback or replacement exists.

✅ Internal assembly, capability retrieval/lifecycle overloads, lazy registration and explicit diagnostics.
❌ Dynamic model selection and physical-device acceptance are not provided by this change.

✅ ModelKitDefaults.manager(resources:) returns the process-wide manager. Concurrent calls share assembly and provider instances; conflicting resource roots fail. Construction/registration are assembly SPI. Each model admits one active operation, rejects overlap with inputBusy, and releases admission only after cleanup. Cross-model scheduling is not implemented.
