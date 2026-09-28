# IntegrationTests

Purpose: verify composed Agent, Gateway, Action, Tool, Storage and voice contracts with injected model/device substitutes. Design goals: exercise real boundaries and failure paths without presenting a simulator or test double as physical-device acceptance.

## Current coverage

- ✅ `FunctionTokenParserTests` covers fragmented UTF-8, escaped text, nested Channels, malformed and oversized input, Action resolution and native Tool syntax.
- ✅ `AgentConfigurationTests` covers packaged JSON v4 declarations, metadata, examples, capability visibility, path/Channel validation and malformed or missing configuration. Production permission lists remain in Agent JSON.
- ✅ `ActionExecutionTests` and `RuntimeTests` cover Channel ordering, resource exclusion, bounded admission, cancellation, failure isolation and completion barriers.
- ✅ `CommunicationTests` covers static and directed routing, schema/source checks, admission deadlines, state replacement and independent session cleanup.
- ✅ `VoiceTests`, `SentenceFunctionTests`, `SpeechPlaybackTests`, `PCMResamplerTests` and `StorageTests` cover VAD/ASR observations, captions, Assistant output segmentation, synthesis requests, audio-ID playback, starvation/timeout, resampling, cache leases and expiration. `FixedTextChat` and `SpeechRequestProbe` are test fixtures only.
- ✅ `PhotographyPipelineTests` and `CameraSamplingTests` cover frame sampling/filtering, shared pose inference, current VisionPerception publication and completion-only `UI.showPose` Tool delivery with zero or multiple subscribers. The photography test filename reflects an earlier design; no Photographer Agent is packaged.
- ✅ `EyeTrackingTests` covers pose-derived eye movement and related presentation Actions with injected services.
- ✅ `AssistantChatTests` verifies chat request context, history, expression metadata, hidden capability visibility, malformed output recovery and later-turn continuity.

## Acceptance still required

- ❌ Real microphone/camera behavior, model accuracy, playback and expression appearance, hardware latency, thermal stability and sustained conversation require physical-device testing. Passing this suite establishes protocol behavior with controlled inputs only.

Update this README when test responsibilities change; dated run results belong in [validation history](../../docs/Validation-History.md).

✅ Local document tests cover reopen, cached reads, explicit refresh/invalidation, stale and concurrent writers, size bounds and corrupt-file cache preservation. ❌ Keychain migration requires device acceptance.

✅ FunctionTokenParserTests also covers GenerationTrace: exact raw/fragment preservation, equivalent production parsing and Channel resolution, continuing collection after parser failure, incomplete markup at finish and explicit byte/fragment overflow without eviction.


✅ Structured wait coverage includes byte-fragmentation invariance, lexical nesting/cross-close errors, empty and consecutive groups, reserved aliases, group/depth limits, ordered Assistant speech conversion, entry/exit joins, streaming nested execution, dormant-capacity accounting, task Action limits, module exclusion, independent-task progress and cancellation cleanup. Gates and handler signals verify execution dependencies without timing-based assertions. ❌ Live model syntax compliance and physical timing require device acceptance.

✅ Prompt regression verifies English production guidance, visible Action details grouped by default Channel, stable audio-Channel guidance independent of mapping order, hidden-call/text-effect/Tool exclusion and explicit invalid-mapping failures. ❌ These checks do not measure live-model instruction following.

✅ ConversationHistoryTests covers durable raw/request restoration, interrupted generation, exact ten-round context, failed-round exclusion, atomic archive/reset, raw overflow preservation, parser-failure recording, cancellation and isolated title generation. Assistant request tests now expect history across voice sessions. ❌ These fixtures do not establish real-provider title quality or device performance.

✅ JSON v5 uses Channel-grouped callable Actions; Assistant text interpretation uses Assistant.mapText rather than JSON aliases. Regression coverage checks internal permissions cannot be called through model markup and preserves wait event order. ❌ Live-model/device acceptance is separate from automated checks.

✅ Chat output-token budgets are optional and default to nil. Assistant/cloud requests omit max_tokens so the provider chooses its default; local Qwen uses remaining room in its existing 4096-token context. History shows 模型默认 for omitted values and preserves older explicit budgets. The separate 2000-byte whole-reply cap is removed; parser, queue, timeout and per-segment bounds remain. Explicit title/warmup budgets are unchanged. ❌ Live-provider/device acceptance remains separate.
