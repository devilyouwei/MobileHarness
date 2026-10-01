# ADR 0035: YOLOv8 Pose capability

> Historical scope: Historical model choice. [ADR 0038](0038-yolo26-pose.md) replaced YOLOv8 with YOLO26n-Pose.

Accepted: 2026-09-26.

The requested model is an image-input Core ML graph with raw pose outputs; the existing tensor-only Silero backend cannot accept it directly. Add a separate CoreMLImageGraph backend and ModelKitYOLOPose adapter under Vision/YOLO, with a model-independent PoseCapability and bounded RGB8 ImageFrame. Management depends only on the base capability; Defaults selects n and provides lazy `.pose` registration with idle eviction.

One request holds one resource lease through aspect-fit letterbox preprocessing, prediction and bounded NMS decoding. Cancellation joins backend work before release. No camera ownership, model identity or Core ML types cross the capability boundary. Original pixel coordinates preserve off-image points. The adapter README defines exact thresholds and limits.

Development provisioning pins the upstream revision; weights remain outside Git and outside the current voice app staging whitelist. Local package compilation is supported, and precompiled artifacts are preferred for app deployment. The upstream model card labels weights AGPL-3.0.

✅ Model-layer contract, implementation and deterministic tests.
❌ Human-image accuracy, iPhone runtime/thermal validation and gateway-mediated camera/Agent integration.

Amendment (2026-09-26): replace scalar Swift image loops with Accelerate/vImage and per-value MLMultiArray bridging with scoped typed bulk access. Keep immutable RGB capability transport and all Gateway/Agent contracts. The graph owns one reusable BGRA output and optional bounded source scratch; a shared validated layout drives both preparation and inverse coordinates. vImage resampling changes edge pixels relative to the original bilinear/nearest-neighbor implementations, requiring visual accuracy re-acceptance. Add phase signposts and opt-in host microbenchmarks; do not infer ANE usage or phone FPS from host results.
