# Vision capabilities

Purpose: model-independent visual inference contracts. Design goals: immutable Sendable inputs/results, bounded requests, no camera or business dependencies.

✅ PoseCapability accepts one unmirrored ImageFrame with upright geometry (RGB or native storage) and returns person boxes and COCO-17 joints in original-image pixels with top-left origin. Confidence values remain model scores; low-confidence joints are retained for consumers to interpret. Results carry the request context. Image transport belongs to Core.

✅ YOLO is a separate concrete adapter target; consumers receive `manager.get(.pose)` from the shared default manager. One image per call, no frame queue.
❌ Tracking identities and model-level video sessions. Camera capture/orientation and Photographer integration are implemented outside ModelKit.

✅ PoseCapability accepts ImageFrame in RGB or retained native BGRA storage; native orientation is resolved by the backend and result coordinates use upright image dimensions. Apple Vision/Core ML with CPU+ANE is the native YOLO26 baseline. The end-to-end model head produces candidate rows; Swift filters scores and restores coordinates without a second NMS. PlatformKit/Vision owns camera I/O, not this inference. The shared domain name does not create a dependency between the Kits.
