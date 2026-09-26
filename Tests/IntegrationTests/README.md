# IntegrationTests

Purpose: verify composed Agent, Gateway, Action, Tool and voice contracts. Test doubles isolate models/devices; passing tests does not establish physical-device user experience.

- ✅ FunctionTokenParserTests: every UTF-8 split point, bytewise input, text escaping, nested channel restoration, malformed/truncated/oversized input, Agent integration and native tool parsing. See the [protocol definition](../../MobileHarness/AgentCore/Generation/README.md).
- ✅ ActionExecutionTests: channel ordering, cross-module concurrency, shared-module exclusion, queue/channel limits, failure isolation and cancellation/completion barriers.
- ✅ Voice, model injection, history, sentence segmentation and lifecycle regression coverage.
- ✅ AgentConfigurationTests: bundled JSON v3 resources, metadata/doc retention, required/unknown fields, invalid types/versions, duplicate parameters, identity/size limits, text mapping and path/channel changes. Legacy plist input is rejected; missing command capabilities fail without crashing.
- ✅ Visible-example validation, XML errors, hidden defaults/types, hidden Action references, tool visibility and unchanged text-to-speak/print mapping.
- ✅ ActionPath and Speech/UI bindings, independent ActionRuntime and ToolExecutor; aliases and default channels remain compatible.
- ✅ LiveSpeechInput and StreamingMonoPCMResampler cleanup regressions. FixedTextChat is test-only; production Assistant requires injected ChatCapability. Neural VAD boundary tests live in SileroTests.
- ✅ Local Action text validation before side effects: missing/blank/oversized UTF-8 input and preservation of accepted formatting at the 2000-byte boundary. Voice tests cover empty synthesis and cancellation.
- ✅ Expression validation before presentation and propagation of callback cancellation. Configuration includes express; unregistered smile alias is rejected, while express with emotion=smile resolves correctly.
- ✅ Actual Assistant ChatRequests on initial, continued and new-session turns include visible express metadata and exclude hidden say/print metadata. Both visible and hidden native Tool metadata are excluded while Tool resolution remains available.
- ❌ Physical microphone, playback quality, expression appearance, model emotion selection and sustained conversation acceptance require device testing.

Update this README when adding or changing tests. Preserve ✅/❌ distinctions between automated coverage and outstanding acceptance work. Fragmentation, ActionCall routing and failure tests verify current protocol behavior.

- ✅ Assistant malformed XML, truncated channels, invalid entities and unknown Action recovery: one error terminal, no successful completion or failed-turn history, and a successful next turn on the same Agent/session.

✅ Adapter fixtures explicitly own ModelContext; managed weight teardown is independent of capability/session consumption. Shared registration/reuse tests live under root Tests/ModelKitRuntimeTests.

✅ PhotographyPipelineTests covers normalized grayscale threshold and previous-examined-frame semantics, duplicate rejection, latest-only delayed model processing, pause/stop, stale result suppression, pose Action validation, projection and Gateway → Agent → output Action completion.

✅ Camera conversion regression fixtures cover padded source rows, all four clockwise rotations, RGB channel order and 720p-to-640-long-edge bounds using native vImage.

✅ Native-camera sampling fixtures cover padded rows and all four orientations. Sampled ImageInput tests verify unchanged threshold/baseline admission and malformed sample rejection; previous camera RGB-conversion fixtures were replaced with these current-path tests.




✅ CommunicationTests covers static/direct delivery, stale source ports, schema rejection, high-rate states, pending replacement, slow-target deadlines and independent scope close. VoiceTests exercises PCM → SpeechPerception → final observation; PhotographyPipelineTests verifies two subscribers share one inference and empty pose clears UI.

Validation (2026-09-26): final scripts/check.sh passed, including 79 IntegrationTests, configuration and module-boundary checks. All four scripts/build-ios.sh simulator schemes passed; MobileHarnessSimulator was rebuilt after the final capture-gating fix. The unsigned MobileHarness device target built successfully. All four packaged Agent JSON resources are v4 and byte-identical to source. Original Technical_Design.docx is unchanged. Optional real-model evaluations were not enabled; no phone installation or continuous physical audio/camera/thermal acceptance was performed.

✅ VoiceTests verifies PCM → speech events plus configured UI.setTranscript Actions through OutputGateway/scheduler/handler, preview-before-clear ordering, one terminal clear, empty text validity, payload limits and cancellation propagation.

✅ PhotographyPipelineTests covers VisionPerception-owned skeleton Actions, shared inference for multiple observers, empty overlays, six-person projection, foreign-session rejection, standalone visualization without subscribers, cancellation and output overflow.

✅ VoiceTests proves speech onset Signal delivery alone does not alter presentation; Assistant must emit validated UI Actions and complete through the scheduler before expression/reply clear handlers run.

✅ Strict UI regression: speech.phase publication alone does not touch presentation; Assistant emits express(clear)/clearReply through OutputGateway and the scheduler. Speech preview/clear and phase presentation use declared UI Actions. Device visual acceptance remains outstanding.

✅ Void tool tests verify nil feedback, direct failure/cancellation propagation, cross-kind duplicate registration and the distinction between empty String results and Void. Camera pipeline tests run UI.showPose through ToolRuntime with no Action handler and with zero/two pose subscribers; VisionPerception does not accept ToolResult inputs.

✅ Turn presentation tests cover delayed partials after final, old turns, same-ordinal conflicting IDs, component sequence ordering, wrong producer and beginReplyTurn idempotency. These are automated state/protocol tests, not device visual acceptance.

✅ Visual freshness tests block publication explicitly while inference/display progress, verify one latest pending observation, stop/join cancellation, nine unconsumed overlays collapsing to the newest without Agent failure, and bounded refresh with no sequence replay.
