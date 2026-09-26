# Project tests

Purpose: verify contracts and application integration in separate test targets. Design goals: one source tree and explicit test dependencies.

❌ Test success alone does not establish physical-device acceptance.

✅ All model tests live under this root. Qwen35Tests contains model-only checks; AgentModelEvaluationTests contains application prompt experiments. No tests live inside MobileHarness/ModelKit.

✅ ModelKitDefaultsTests checks internal production assembly independently of App; model factory and capability-mapping contract tests remain isolated from business Agents.

✅ YOLOPoseTests covers RGB boundaries, letterbox geometry, NMS and pose registration; YOLO_POSE_MODEL_ROOT enables real-model smoke and lifecycle checks. ❌ Human-image/device accuracy remains manual acceptance.

✅ IntegrationTests/PhotographyPipelineTests exercises the new camera-to-Photographer-to-UI action pipeline with injected model doubles; native camera/device visual quality still requires device acceptance.
