# ModelKitAppleSpeechTests

Purpose: validate system speech policy and PCM transport, with explicit model contexts. Design goals: deterministic contract tests and explicit separation of real-model acceptance.

- Tests use explicit contexts for isolated adapters; shared-container behavior is tested in ModelKitRuntimeTests.
- Invalid inputs and lifecycle failures remain observable; no production fallback implementations are added for tests.

Update this README when test scope or lifecycle contracts change.

Isolated adapter fixtures explicitly import ModelManagement SPI to own test lifecycle; production adapters receive their context from the manager.

Modern Apple ASR rejects invalid requests before loading. HARNESS_TEST_SYSTEM_ASR_WAV enables real on-device SpeechAnalyzer fixture recognition, final output and lease reuse; it may install Apple language assets. HARNESS_TEST_SYSTEM_TTS enables real system PCM synthesis.

Apple ASR input uses bounded backpressure under bursts of pre-roll PCM. The real Chinese fixture test sends 137-sample packets without pacing and verifies final recognition and lease reuse.

Opt-in consecutiveSystemRepliesReleaseAdmissionBeforeNextRequest performs four real Apple short replies with immediate consumption and no inter-request pacing. Physical-device acceptance remains pending.

Apple TTS resolves the production auto locale to zh-CN when text contains Han characters, otherwise en-US. Explicit locales retain their requested language/region, with zh/en script aliases normalized. Missing voices remain an explicit error with the resolved language. Consecutive real TTS integration uses auto rather than an explicit zh-CN fixture.

Combined Apple native ASR+VAD integration sends dense 137-sample Chinese PCM plus two seconds of silence through one analyzer. Native VAD events require actual provider evidence; no synthetic positive event substitutes for it.

## Streaming TTS latency

Regressions cover for immediate first PCM including short output, byte/sequence/timestamp preservation, format rejection, and opt-in consecutive/cancelled native synthesizer reuse. Controlled PCM checks do not certify phone latency.

## 待实现

- iPhone 原生 ASR/TTS 连续调用、声学竞争和持续稳定性验收。
