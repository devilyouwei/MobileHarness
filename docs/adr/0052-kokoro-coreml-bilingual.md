# 0052 — Local Kokoro Core ML bilingual synthesis

Date: 2026-09-28. Supersedes ADR 0050's English-only synthesis selection.

## Decision

Replace the ModelKitKokoro implementation with FluidAudio's seven-stage Core ML pipeline, pinned to 20d4f0bd46d11d7f50a6eb4f7835cfdbd2b4ba14. ModelKitFluidAudio is the dedicated external-SDK backend; base ModelKit, Agents, Actions and ModelKitRuntime remain independent of FluidAudio.

Provision English and Mandarin graphs, voices and pronunciation data under Models/KokoroCoreML. Downloads use fixed development profiles; the app validates all local dependencies before invoking lower-level SDK stores. Do not invoke the high-level SDK manager, its global G2P singleton or runtime frontend download helpers. Core ML resources and both frontends belong to one ModelResource. The SDK's metadata migration path is prevented by rejecting incompatible local graphs before loading.

SpeechActions uses locale auto. The adapter segments Mandarin and English runs in original order, selecting zf_001 or af_heart; mixed speech may change voice. Assistant returns to the user's language and JSON documents supported speech inputs. Other languages fail explicitly; this stage implements Mandarin/English, not every language listed upstream.

Existing queue, gateway, lease cancellation and playback completion contracts are preserved. Frontend segments are bounded to 32, graph inputs to 510 phoneme scalars and total PCM to 60 seconds. Unknown symbols cannot be silently discarded by the SDK vocabulary encoder. English remains dictionary-first; Mandarin adds number/date normalization, tone sandhi and g2pW. The SDK's optional NeMo binary trait is disabled; the Mandarin in-process normalizer is used.

## Stability and validation

Upstream #889 documents iOS 27 process crashes. The pinned implementation includes one-page padded graph buffers to mitigate the suspected BNNS input overread and uses ANE with CPU noise/tail. The mitigation has upstream Mac evidence but needs an iPhone endurance run. Report this limitation rather than claiming production stability or silently switching engines.

Run root checks, simulator builds and real model tests for English, Mandarin, mixed text and Mandarin dates/numbers. Confirm input/output limits, nonempty finite/non-silent PCM, cancellation and unloaded state; manual sound quality and iPhone endurance remain separate acceptance.
