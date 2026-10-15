# ADR0178 — Bounded native result continuation

Accepted: 2026-10-08. Design precedes code.


## Bounded native result continuation

✅ Implemented: Assistant correlates model-native calls with runtime-only feedback under the original turn, awaits complete results and requests the next model round. Limits: four total model rounds,16 native calls,64 KiB aggregate feedback/transcript and one30-second joined generation worker. A failed call becomes data for the model, never an automatic function retry. Cancellation clears owned feedback state and joins model cleanup; unknown/stale/duplicate feedback cannot resume a turn. Internal UI receipts and explicit /status retain their existing handling.

✅ Implemented: ModelKit ChatMessage gains provider-neutral assistant tool-call declarations and tool-result messages. OpenAI serializes request-local aliases consistently across declarations and prior calls; Gemma rejects native transcripts explicitly. Storage keeps optional exact continuation request JSON bytes as data, with bounded records and unchanged v1 compatibility. Camera native model calls use returning protocol registration so actual completion/error can continue reasoning. No change to camera or NexArm function implementation.

No new directories, dependencies or native business algorithms. Model continuation permits choosing a new function but the runtime never replays prior effects. Physical/live-provider acceptance remains separate.

Failed Tool messages include an explicit error flag/code and the exact native value as data. The final permitted round waits for issued calls before declaring the round bound; it does not start a fifth request. See [validation history](../validation/Validation-History.md).

Native failure messages also preserve any producer report and its partial-failure status, complete leaf outcomes and execution-level cause, within the existing transcript bounds.
