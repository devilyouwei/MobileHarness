# ADR 0051: OpenAI-compatible cloud chat

> Historical scope: Historical adapter-only stage. [ADR 0053](0053-settings-live-chat.md) added the settings UI, Keychain storage and immediate selection; real-provider acceptance remains open.

Accepted 2026-09-28.

Third-party cloud text models must be usable without exposing endpoint/provider identity to Agents or adding a dependency from the capability SDK to network implementations.

Use a separate ModelKitOpenAI target under Language/LLM/OpenAI. It implements the existing ChatCapability through Chat Completions SSE. Defaults accepts optional explicit HTTPS endpoint/key/model/timeout configuration, and internally binds the chat provider. The App retains responsibility for obtaining credentials securely. No credential is stored by the adapter. No automatic fallback or live selection changes are introduced.

The process singleton fixes configuration alongside the resource root and rejects conflicts. A lightweight ModelResource makes remote requests participate in admission, unload and shutdown. One active request is admitted; no inference queue. Cancellation invalidates the HTTP operation before releasing the lease. Stream framing and output are bounded and fail on overflow. Truncation, native tools and unsupported finishes propagate failures; remote bodies and credentials never appear in surfaced errors. Availability describes local configuration, not verified remote service health.

✅ Offline request/framing and lifecycle verification is independent of local model weights. Consumers and Gateway contracts are unchanged; model output follows existing Agent → OutputGateway routing.
❌ Cloud speech/vision/judge, native tool calls, credential UI/persistence, automatic retries and real-provider/device acceptance remain separate work.

Validation: six isolated offline tests passed. Root check and full iOS build were attempted but blocked by concurrent FluidAudio/Kokoro edits (formatting and missing KokoroInput.Segment); the cloud adapter compiled for both simulator architectures. Real-provider behavior has not been verified.
