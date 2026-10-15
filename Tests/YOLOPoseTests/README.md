# YOLO pose tests

Purpose: validate pose transport, preprocessing, raw decoding and lifecycle. Design goals: deterministic geometry fixtures and explicit opt-in model execution.

✅ RGB bounds, padding, end-to-end decoding without NMS, coordinate restoration, malformed tensor rejection, typed registration and missing artifacts.
✅ Opt-in blank-image inference / unload / reload / shutdown via YOLO_POSE_MODEL_ROOT.
❌ Human-image accuracy, cancellation under device load and iPhone performance acceptance.

✅ Native preprocessing tests cover RGB/BGRA channels, constant-color resampling, exact 114 padding, buffer reuse across aspect-ratio changes, malformed dimensions and source byte count. Tensor extraction tests cover Float16/Float32/Double and contiguous, padded and transposed storage, plus unsupported types. Overlapping output rows must remain distinct; old raw-head shape, invalid classes/scores and malformed coordinates are rejected.
✅ `POSE_PERFORMANCE_CHECK=1 swift test --filter poseProcessingPerformance` compares warmed host medians (five iterations) with the pre-optimization letterbox/tensor reader retained only as test references. Old preprocessing timing covers RGB letterbox only; new timing includes the full RGB-to-model buffer step. No timing threshold is used. ❌ These microbenchmarks exclude camera, prediction and UI, and cannot claim phone throughput.

✅ Native tests cover dimensions/orientation, continuous scaleFit offsets and opt-in real Vision inference in four orientations. POSE_VISION_BENCH=1 plus YOLO_POSE_MODEL_ROOT enables an isolated warmed Vision vs vImage/direct and CPU+ANE vs all host baseline (five samples after three warmups). Square constant input excludes realistic resampling/accuracy claims; total includes tensor extraction, and is not sustained camera FPS.

✅ All real-model tests and benchmarks now load yolo26n-pose only. Tensor fixtures are [1,300,57] in contiguous, padded and transposed layouts. Earlier YOLOv8 benchmark values are historical; rerun before making new performance claims.


✅ Fixtures use UUID/opaque runtime strings and committed database business references; concurrency, restart, invalid-ID and failure behavior remain covered.

## Identity ownership

✅ Runtime and foundation identities use opaque protocol strings or Foundation UUID; no project ID-generator dependency exists. SQLite-backed Storage publishes committed business references and App injects repositories/maps native Bluetooth identities. Tests preserve caller identity, cancellation and failure semantics. See [current storage design](../../MobileHarness/Storage/README.md) for relational allocation and persistence.
