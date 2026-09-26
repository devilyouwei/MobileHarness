# YOLO pose tests

Purpose: validate pose transport, preprocessing, raw decoding and lifecycle. Design goals: deterministic geometry fixtures and explicit opt-in model execution.

✅ RGB bounds, padding, NMS, coordinate restoration, malformed tensor rejection, typed registration and missing artifacts.
✅ Opt-in blank-image inference / unload / reload / shutdown via YOLO_POSE_MODEL_ROOT.
❌ Human-image accuracy, cancellation under device load and iPhone performance acceptance.
