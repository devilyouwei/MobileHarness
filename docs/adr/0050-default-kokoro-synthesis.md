# 0050 — Default Kokoro synthesis

> Historical model/resource scope: current synthesis selection is [ADR0058](0058-moss-tts-nano.md); current metadata-only packaging, source declarations, explicit acquisition and safe removal are [ADR0105](0105-local-model-resource-management.md). Old bundle-weight, development-profile and Kokoro-default statements below are retained decision history, not current implementation contracts.

> Historical scope: Historical English-only Kokoro default. [ADR 0052](0052-kokoro-coreml-bilingual.md) replaced its model path and language selection with the bilingual Core ML implementation.

Date: 2026-09-28. Supersedes ADR 0016's diagnostic-only selection, not its model limits.

## Context

The requested Kokoro-82M-CoreAI export already has a ModelKit adapter, pinned provisioning and three-stage CPU inference. Conversation still selected Apple speech and sent zh-CN requests. Changing only the provider would reject every speech Action.

## Decision

ModelKitDefaults binds synthesis to the existing kokoro registration, with releaseWhenIdle. Remove Apple speech from production registration and the Defaults target's dependencies; retain the independent Apple adapter and tests. App continues obtaining capability protocols through the process-wide ModelManager. Explicit Kokoro diagnostics and default synthesis resolve to the same provider, resource and single-operation admission.

SpeechActions defaults to en-US. Assistant requests short US English replies, numbers expressed as English words and no Markdown/emoji; its JSON say declaration documents the accepted text. Model instructions are best effort, while Kokoro input validation remains authoritative. Do not translate, discard unsupported text, silently truncate audio or fall back to another synthesizer.

Existing PCM limits, cancellation/lease cleanup, InputGateway/OutputGateway routing and platform playback remain unchanged. Startup loads Kokoro through the existing synthesis load path. Simulator, absent resources and unsupported languages produce explicit errors.

## Validation and remaining work

Default assembly tests assert identity between default synthesis and named Kokoro, lazy registration and failure for absent artifacts. Voice Action fixtures assert en-US. Existing Kokoro tests exercise G2P, bounded chunks/alignment and optional real three-graph inference. Run repository checks, iOS builds and the opt-in model test; record results in Kokoro-Validation.md.

Chinese preprocessing/voices, guaranteed language compliance, sustained iPhone playback and acoustic acceptance remain outstanding. English-only substitution is not multilingual equivalence to Apple speech.
