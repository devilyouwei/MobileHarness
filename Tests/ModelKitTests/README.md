# ModelKit contract tests

Purpose: verify independent capability contracts and bounded inference sessions. Design goals: deterministic fixtures, explicit failure/cancellation and no business dependencies.

✅ SessionTests cover ordered completion, single consumers, explicit synchronous overflow, suspending emission with capacity one and cancellation of a blocked producer. Capability/media/resource tests verify validated independent SDK contracts.
❌ Real-model quality, latency and hardware behavior belong to adapter/device acceptance.

✅ Unbounded sessions retain 20,001 ordered events before consumption, including suspending yield; size validation and cancellation still apply. Existing bounded overflow tests remain.


## Bounded native result continuation

✅ Implemented: Assistant correlates model-native calls with runtime-only feedback under the original turn, awaits complete results and requests the next model round. Limits: four total model rounds,16 native calls,64 KiB aggregate feedback/transcript and one30-second joined generation worker. A failed call becomes data for the model, never an automatic function retry. Cancellation clears owned feedback state and joins model cleanup; unknown/stale/duplicate feedback cannot resume a turn. Internal UI receipts and explicit /status retain their existing handling.

✅ Implemented: ModelKit ChatMessage gains provider-neutral assistant tool-call declarations and tool-result messages. OpenAI serializes request-local aliases consistently across declarations and prior calls; Gemma rejects native transcripts explicitly. Storage keeps optional exact continuation request JSON bytes as data, with bounded records and unchanged v1 compatibility. Camera native model calls use returning protocol registration so actual completion/error can continue reasoning. No change to camera or NexArm function implementation.

## ModelKit Support ownership

✅ Five deterministic InferenceTaskControl regressions cover cancel-before-install, installed cancellation/isolation, finish-before-install, finish cleanup and duplicate worker rejection. Owners join all fixture workers; no timing sleeps or real models are required.

✅ CoreBoundaryTests cover opaque scope propagation, invalid injected limits, global load admission, waiter rejection, explicit retry and residency without importing Management.
