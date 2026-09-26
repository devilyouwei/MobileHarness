# Vision capabilities

Purpose: model-independent visual inference contracts. Design goals: immutable Sendable inputs/results, bounded requests, no camera or business dependencies.

✅ PoseCapability accepts one upright, unmirrored RGB8 ImageFrame and returns person boxes and COCO-17 joints in original-image pixels with top-left origin. Confidence values remain model scores; low-confidence joints are retained for consumers to interpret. Results carry the request context. Image transport belongs to Core.

✅ YOLO is a separate concrete adapter target; consumers receive `manager.get(.pose)` from the shared default manager. One image per call, no frame queue.
❌ Tracking identities and model-level video sessions. Camera capture/orientation and Photographer integration are implemented outside ModelKit.
