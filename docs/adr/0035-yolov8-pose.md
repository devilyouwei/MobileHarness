# ADR 0035: YOLOv8 Pose capability

Accepted: 2026-09-26.

The requested model is an image-input Core ML graph with raw pose outputs; the existing tensor-only Silero backend cannot accept it directly. Add a separate CoreMLImageGraph backend and ModelKitYOLOPose adapter under Vision/YOLO, with a model-independent PoseCapability and bounded RGB8 ImageFrame. Management depends only on the base capability; Defaults selects n and provides lazy `.pose` registration with idle eviction.

One request holds one resource lease through bilinear letterbox preprocessing, prediction and bounded NMS decoding. Cancellation joins backend work before release. No camera ownership, model identity or Core ML types cross the capability boundary. Original pixel coordinates preserve off-image points. The adapter README defines exact thresholds and limits.

Development provisioning pins the upstream revision; weights remain outside Git and outside the current voice app staging whitelist. Local package compilation is supported, and precompiled artifacts are preferred for app deployment. The upstream model card labels weights AGPL-3.0.

✅ Model-layer contract, implementation and deterministic tests.
❌ Human-image accuracy, iPhone runtime/thermal validation and gateway-mediated camera/Agent integration.
