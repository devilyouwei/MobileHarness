# Language capabilities

Purpose: Group language-generation and judgment protocols with concrete model adapters.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- ✅ LLM text chat and JEV judgment contracts; Gemma4 is the current chat adapter.
- ✅ Cloud image input through LLM. ❌ Local image chat, embedding and a concrete judgment provider.


## Bounded registered-observation continuation

✅ Implemented: Assistant correlates generated Action/Tool calls with runtime-only feedback under the original turn, awaits complete results and requests the next model round. Limits: four total model rounds,16 native calls,64 KiB aggregate feedback/transcript and one30-second joined generation worker. A failed call becomes data for the model, never an automatic function retry. Cancellation clears owned feedback state and joins model cleanup; unknown/stale/duplicate feedback cannot resume a turn. Internal UI receipts and explicit /status retain their existing handling.

✅ Implemented: ModelKit ChatMessage gains provider-neutral assistant tool-call declarations and tool-result messages. OpenAI serializes request-local aliases consistently across declarations and prior calls; Gemma rejects native transcripts explicitly. Storage keeps optional exact text/native continuation JSON and metadata-only image descriptors as data, with bounded records and unchanged v1 compatibility. Camera native model calls use explicit observation registration so actual completion/error can continue reasoning. No change to camera or NexArm function implementation.

## Assistant photo observation — ADR0184

✅ Implemented: LLM requests support bounded user-message image attachments; concrete local provider remains text-only.

❌ Real camera/shutter/animation and configured-model vision acceptance remain pending; video recording and system Photos export are outside this iteration.
