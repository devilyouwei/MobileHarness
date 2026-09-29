# Project tests

Purpose: verify contracts and application integration in separate test targets. Design goals: one source tree and explicit test dependencies.

❌ Test success alone does not establish physical-device acceptance.

✅ All model tests live under this root. Qwen35Tests contains model-only checks; AgentModelEvaluationTests contains application prompt experiments. No tests live inside MobileHarness/ModelKit.

✅ ModelKitDefaultsTests checks internal production assembly independently of App; model factory and capability-mapping contract tests remain isolated from business Agents.

✅ YOLOPoseTests covers RGB boundaries, letterbox geometry, NMS and pose registration; YOLO_POSE_MODEL_ROOT enables real-model smoke and lifecycle checks. ❌ Human-image/device accuracy remains manual acceptance.

✅ IntegrationTests/PhotographyPipelineTests exercises camera input, shared pose inference and the VisionPerception skeleton display path with injected model doubles; native camera/device visual quality still requires device acceptance. The test filename records the earlier Photographer design.

✅ test_model_download.py contains offline ZIP hash/member/path/symlink and replacement-preservation tests, invoked by scripts/check.sh. YOLOPoseTests use the new end-to-end model/output contract.

✅ Integration coverage includes shared inference, v4 policy, event bounds, latest-state replacement, deadlines and independent session cleanup. VAD boundary tests import Agents; model adapter tests remain separate.

✅ Skeleton visualization regression coverage belongs to VisionPerception in IntegrationTests; no Photographer runtime is required.

✅ IntegrationTests covers direct no-feedback skeleton Tool calls while preserving normal ToolResult round trips.

✅ OpenAIChatTests independently checks cloud chat encoding, bounded SSE and managed lifecycle with local URLProtocol fixtures. ❌ Live-provider acceptance is separate.

✅ IntegrationTests cover Storage document cache/disk synchronization, concurrent revision conflicts, bounded I/O, unsupported schemas and invalid files. ❌ Device Keychain migration acceptance is separate.


✅ MossNanoTests covers input/PCM bounds and an opt-in local-model synthesis/lifecycle smoke test. ❌ Mac smoke does not establish iPhone quality or stability.

✅ UITests and AppWorkflowTests exercise form-save lifetime, archive-before-title, operation admission and cancellation/retry with controlled completion signals; they create no device or real model. ❌ Device interaction acceptance remains separate.

✅ IntegrationTests includes Action runtime stage 1 contract checks and preserves existing Channel/wait, speech and presentation regressions. ❌ Activity owners, resource leases and physical-device timing remain later acceptance.

## Action runtime stage 2

✅ IntegrationTests/ActionLifecycleTests adds stage-2 contract coverage for bounded Action feedback and resource leases/fences. ❌ Real-device lifetime/takeover tests remain separate.

## Domain-owned behavior assembly

✅ IntegrationTests depends on the pure BehaviorAssembly target to test module construction without compiling the iOS App. ❌ These tests do not validate native effects.

## Action implementation audit

✅ IntegrationTests now includes the Action authoring audit regression cases; no physical-device acceptance is implied.
