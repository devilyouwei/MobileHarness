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

✅ Event migration stage 1: JSON v4 communication declarations, typed perception inputs, static subscription/direct delivery, bounded event transport and incarnation fencing. ❌ Production perception agents and shared App composition follow in subsequent stages.

✅ Speech migration: SpeechPerceptionAgent owns VAD/ASR and publishes validated observations; InputGateway no longer holds recognition capabilities. App submits PCM through Gateway and observes speech through OutputGateway. ❌ Shared camera composition follows in stage 3.

✅ Vision migration: VisionPerceptionAgent owns filtering/inference and publishes shared pose observations; Photographer owns only display policy. App now uses one shared manager/bus/Gateway assembly with independent voice and camera sessions. ❌ Device acceptance remains outstanding.
