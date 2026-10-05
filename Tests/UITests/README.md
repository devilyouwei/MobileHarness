# UI State and Interaction Tests

Purpose: verify page state and injected-operation behavior without App, model or device implementations. Design goals: deterministic completion signals and independent module compilation.

Root Package.swift compiles this directory as UITests against the UI module. These are Swift unit tests for state and operation contracts; native UI automation remains separate.

✅ Configuration saves remain admitted across page disappearance/discovery cancellation; overlapping saves reject, failure releases the slot and retry succeeds. Repeated restoration preserves unsaved edits.

❌ Native rendering, navigation gestures and physical-device layout/animation acceptance.

✅ Composed Action history tests preserve all child issue descriptions beyond the compact summary. ❌ Real-device accessibility and long-history visual acceptance remain outstanding.

✅ Action-result translation tests moved to AppWorkflowTests, matching the App-owned mapping boundary.

✅ ModelResourcesStateTests 覆盖即时锁定、重复下载/删除拒绝、提交与取消的顺序、取消重复点击拒绝、失败后重试，以及刷新失败时保持已提交下载锁定。使用注入操作，无网络或模型权重。❌ SwiftUI 设备渲染不由这些状态测试验证。


✅ Legacy single speech-switch JSON decodes into independent recognition/synthesis flags; new JSON round-trips independent modes and no longer emits preferDownloadedSpeech.

✅ Failed speech-preference saves restore the visible active policy and retain an error.


✅ Speech switches validate/persist against the saved download source, preserving unfinished endpoint edits in the form. Changing voice mode never implicitly commits a draft download domain. Missing prerequisites bounce the switch and present the installation notice.

✅ Recognition prerequisite tests distinguish the displayed Nemotron/Silero cards from the required Nemotron installation; Silero alone cannot enable custom ASR.

✅ Automatic source tests verify persistence before admission, durable voice preference preservation, cellular permission, failed-save admission rejection and retry with the retained endpoint.

✅ Local chat configuration now targets Gemma 4 E2B CoreAI; Qwen/MLX production bindings are removed. ❌ Real-model/device acceptance is separate from compilation and contract tests.

✅ Settings state tests use UI and Foundation directly; no unused AgentCore import remains. ❌ Native UI automation is separate.

✅ AudioDetectionStateTests verifies direction expiry independently of PCM freshness, missing-audio metering, retained unavailable/quiet status and cleared executable angles. ❌ Native rendering and real angle precision remain separate.

✅ BluetoothConnectionStateTests verifies execution messages/manual activity cannot alter native status. Row intent distinguishes connect/open/unavailable; grouping retains remembered devices through unsuccessful new selections and current reasons stay scoped to their attempted device. Disconnected controls remain disabled. ❌ SwiftUI device rendering and return gestures remain separate acceptance.

✅ Bluetooth connection label fixtures use native connection/recovery and active manual state; retired execution/verification fields are removed. ❌ Native rendering remains separate.

✅ ADR0134 / ADR0138: Bluetooth state tests cover row intent transitions (connect / open detail / unavailable), connected-versus-remembered grouping, unsuccessful selection retention while discovery clears, attempted-device reason isolation, unavailable radio/recovery admission, current native warning replacement and disconnected motor/action admission. Shared/pending destination state stays removed; one view-local destination is assigned only by a connected-name tap. No diagnostic history protocol/value remains. ❌ Native single-level/cancelled swipes and compact-row layout require phone acceptance.
