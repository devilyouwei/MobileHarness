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
