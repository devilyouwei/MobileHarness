# ADR 0038 — Replace YOLOv8 with YOLO26n-Pose

Accepted: 2026-09-26. Supersedes the model/output selection in ADR 0035 and raw-head assumptions in ADR 0037.

Purpose: use the official current INT8/end-to-end pose model without carrying an old provider. Design goals: verified reproducible provisioning, small output processing and unchanged capability/Agent/Gateway interfaces.

The official v8.3.0 release asset 487599229 (`yolo26n-pose.mlpackage.zip`) has SHA-256 a809a889f1d324299090c6d9f4211ddd3588cc525f5f78d79691de45bd12f042. A profile pins the archive digest/size and each member digest because release asset URLs can be replaced. Extraction rejects unexpected members, escaping paths and symlinks, verifies before installation, and restores the existing package if replacement fails. No model conversion dependency is added. AGPL-3.0 is declared by the artifact and its license remains bundled.

The inspected metadata declares Pose26/end2end=True/quantize=8; RGB image input is 640×640, sole Float32 output is var_1566 [1,300,57]. Each row is xyxy/confidence/class then 17 x/y/confidence triples. Backend uses the descriptor's sole output name and validates the shape; old raw outputs are rejected. CPU postprocessing only filters confidence, establishes stable score order and restores coordinates. Do not run NMS again on the end-to-end head.

Only yolo26n-pose is registered and packaged. Old downloaded weights, profile/entry point and decoding are removed, without changing PoseCapability, the process singleton, exclusive lease, latest-frame admission or UI Action protocol. RGB/vImage remains an input-format path for the new model, not an old-model fallback.

✅ New artifact downloaded/hash-verified, both native Vision and RGB real-model inference tested, stride/layout and no-NMS decoder fixtures.
❌ New-model human-image accuracy and sustained iPhone latency/pool/thermal acceptance. No published YOLO26 latency or historical YOLOv8 benchmark is claimed as a measurement of this build.
