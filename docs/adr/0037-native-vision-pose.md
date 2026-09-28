# ADR 0037 — Native camera frames and Vision pose inference

> Historical scope: Historical transport and model stage. Its native frame approach remains relevant, but [ADR 0040](0040-shared-perception-and-event-routing.md) moved inference to VisionPerception and [ADR 0038](0038-yolo26-pose.md) replaced the model.

Accepted: 2026-09-26. Supersedes the RGB-only camera transport portions of ADR 0035/0036.

Purpose: remove unnecessary full-frame camera conversions while keeping ModelKit independent and Gateway responsible for admission. Design goals: bounded immutable native-buffer lifetime, explicit adapter boundaries, standard Vision preprocessing and measurable CPU+ANE baseline.

CameraFrame retains the AVFoundation BGRA buffer and carries a small orientation-aware gray sample. AgentCore ImageInput stores an opaque Sendable attachment; only App knows its concrete ModelKit ImageFrame wrapper and injects resolution into PhotographerAgent. Gateway sees dimensions, monotonic metadata and gray samples. Neither AgentCore nor ModelKit depends on the other or on a device adapter. ModelKit may use the public CoreVideo buffer type as data transport; concrete Vision/Core ML execution stays in the backend target.

Raw native references use narrowly scoped unchecked Sendable ownership: no consumer mutates pixels; retention prevents camera recycling. Existing stream/inbox/output/action bounds also bound retained frames. Accepted actions can retain input buffers until finish; pool pressure must be checked on device. Cancellation/stop still joins native work before releasing the lease, with no persistent frame store.

Native inference uses VNCoreMLRequest scaleFit plus explicit orientation. Vision's preprocessing is included in the request interval; padding is not assumed to be RGB 114. Decoder geometry uses continuous centered scaleFit, while RGB/vImage keeps rounded dimensions and 114 padding. The default compute configuration allows CPU and ANE, excludes model GPU execution, and retains explicit all for backend comparison. It does not constrain Vision's preprocessing device or prove actual ANE residency.

The pinned YOLOv8n export remains raw [1,56,8400]; retain Swift NMS/top-k. Switching to an integrated head requires new verified model artifacts/output contracts. No YOLO26 timing is represented as this model's performance, and no RetinaFace/MediaPipe/Metal sharing is scaffolded.

✅ Native/Vision and RGB/vImage paths, typed tensor extraction, sample admission, bounded ownership and phase markers.
❌ Physical-device A/B profiling, human-image accuracy/orientation acceptance, thermal/pool stress and integrated model postprocessing.
