# ADR 0027 — Qwen3.5 chat through MLX

Status: historical implementation decision. Device experiment artifacts were written to local `output/qwen35-mlx-2026-09-25` and are not part of the versioned public documentation; the observations summarized below remain dated evidence, not current model selection or device acceptance.

## Decision

The physical app composes Qwen35Chat using mlx-community/Qwen3.5-4B-4bit revision 0e7ffd5c629ef7719d4cbc04069232580bfa9d9c. ModelKitQwen35 depends only on the base ModelKit capability SDK and the independent ModelKitMLXLanguage backend. The optional package pins MLX Swift LM 3.31.4 and MLX Swift 0.31.4; the existing swift-transformers 1.1.0 tokenizer is bridged to MLX's protocol without upgrading unrelated providers.


ChatRequest/ChatEvent, Agent action registration, system prompt construction, Gateway routing and Actions do not change. The provider accepts up to 64 messages / 64 KiB and 4096 prompt-plus-output tokens, with at most 1024 output tokens. Assistant keeps its smaller existing limits. Sampling honors request temperature with top-p 0.8 and top-k 20. EOS IDs are 248044 and 248046, verified against the bundled tokenizer.

## Lifecycle and bounded execution

ModelManager admits one request at a time and rejects additional requests as busy. The backend constructs a fresh cache for every generation and pulls tokens synchronously into the existing bounded capability emitter (128 events, 4096 bytes/event). It does not create an extra unbounded AsyncStream. Overflow and cancellation terminate generation; GPU work is synchronized before releasing the lease. GPU operations are cooperatively cancelled between operations, not forcibly preempted mid-kernel. Unload waits for the active lease.

## Validation and limits

Ten complete prompt token sequences match upstream Python transformers 5.17.0, including no-thinking template rendering. Real local tests cover generation, cancellation, unload and reload. Mac Swift Testing needs its compiled Metal resource directory discoverable; the test-only harness handles that separately from production. Xcode's Metal Toolchain component is required.

Compilation, model inference, Agent protocol compliance and full microphone/ASR/TTS user acceptance are distinct checks. The recorded device evaluation uses actual Assistant system context and synthetic conversations, not user audio. Runtime performance and broader answer quality are not guaranteed by the model's published benchmarks or artifact size.

The initial 2B device evaluation produced 15/30 XML/parameter failures. The 4B variant was selected for further device validation after improved matched Mac results; the 2B profile remains explicitly selectable for diagnostics. Prompt experiments are recorded without changing production instructions.

The first 4B device attempt terminated with signal 9 before load completion. The physical target now requests the public increased-memory-limit entitlement, as in the official MLX LLMBasic iOS example. The device supplied no matching new Jetsam report, so the initial termination is not asserted to be proven OOM. Entitlement-enabled retry results belong to the dated evidence record.
