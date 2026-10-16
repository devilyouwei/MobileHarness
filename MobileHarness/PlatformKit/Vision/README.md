# Platform Camera and Photo I/O

## Summary

Acquire camera preview, transport immutable native frames, capture one JPEG and import bounded JPEG data into Photos.

## Ownership and boundaries

AppleCamera owns AVCaptureSession mutation on its actor. ActionBindings owns foreground intent, preview geometry and failure presentation. This directory performs no model inference, pose policy or audio capture.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Bindings[Module integrations]
 Bindings -->|start, switch, capture, stop| Camera[AppleCamera]
 Camera <--> Native[AVFoundation camera]
 Camera -->|preview source and newest frames| Bindings
 Bindings --> Photos[ApplePhotoLibrary]
 Photos -->|add-only authorization and joined import| Library[System Photos]
```

## Graph and preview

The graph has one front/back wide-angle input, up to 720p video and one JPEG output. It has no microphone/movie output and disables application audio-session auto-configuration. `CameraPreviewSource` exposes attachment to a native preview layer, without session mutation. ActionBindings selects aspect-fill, mirroring and display rotation.

A healthy `switchCamera(facing:)` replaces only the input inside begin/commit configuration, restores the old input on admission failure, drains/renews the frame stream and reapplies unmirrored sensor settings. It does not restart the session. Permission, running state and no photo in flight are required. Stop closes frames; interruption/error notifications use newest-one status storage.

## Frame contract

Serial AVCaptureVideoDataOutput discards late frames. `CameraFrame` retains private read-only BGRA pixels, upright dimensions, rotation quarter-turn, sequence, media time, monotonic callback instant and a 64×64 gray sample. Consumers use synchronous `withPixelBuffer`; pointers must not escape or mutate storage. The unchecked Sendable wrapper protects lifetime, not arbitrary mutation.

The capacity-one newest stream replaces obsolete observations. A mutex fences stream generation; cancellation affects only its matching generation, and replacement drains the delegate queue. Frames beyond 4096 per side or 4194304 pixels fail. `CameraGraySampler` samples through inverse rotation directly from native pixels, without full-frame rotation/resize or a task per frame. Callback-to-result latency excludes sensor exposure latency.

## Photo lifecycle

One active photo delegate has a ten-second terminal bound. Cancellation checks occur again before native request. Native callbacks are joined before delegate release; old callbacks cannot complete a new photo. Nonempty JPEG is limited to 4 MiB; native shutter behavior is preserved.

`ApplePhotoLibrary.saveJPEG` performs add-only authorization and bounded PHAsset creation. It checks cancellation before authorization and commit. Once issued, import is joined and cannot be rolled back by caller cancellation. It returns technical permission/image failures; photo selection/export receipts belong to ActionBindings.

Foreground camera, native preview/frame transport, healthy input switch, JPEG capture and Photos import.

## Related design

[Parent design](../README.md)

## Native image compression

NativeImageCompression.swift exposes async jpeg(from:limits:) and caller-owned dimension/pixel/byte limits. Image I/O creates a transformed thumbnail directly from encoded data with source caching disabled, then encodes JPEG from the reduced CGImage. This avoids a full-size UIImage decode/redraw and keeps output oriented, aspect-preserving and unscaled above source size. One detached task runs outside MainActor; cancellation is checked before/after native work and between bounded attempts, and the parent always joins it. There is no queue or persistent cache.

Input is one JPEG/PNG, at most 4 MiB, with bounded valid dimensions. Upright JPEG data already within all budgets is reused without decoding/re-encoding; output uses at most four descending thumbnail sizes and three quality attempts per size (initial quality then bounded lower qualities). Native failures and exhausted byte budgets throw; preparation errors never fall back to oversized/untransformed originals. Each attempt releases intermediate allocations through autoreleasepool. Pixels/bytes must satisfy the caller budget. Original input Data is immutable and never written.

[Apple memory guidance](https://developer.apple.com/documentation/xcode/making-changes-to-reduce-memory-use) recommends Image I/O transforms to minimize image memory impact; [thumbnail API](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:)) supports bounded native downsampling/orientation, and [destination API](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/ImageIOGuide/ikpg_dest/ikpg_dest.html) supports JPEG quality selection. No claim that JPEG encoding always runs on a GPU or is the fastest on every device; native latency/quality acceptance remains separate.

✅ CameraVisionRestartWorkflow 是泛型的最新意图替换工具：一个 pending 值、一个切换 worker、一个活跃任务；替换取消旧任务并加入后启动最新意图。stop 清空 pending、取消并加入旧任务；不选择摄像头、感知模型或业务反馈。

## 待实现

- Movie recording and background capture. Physical camera/permission/latency evidence is tracked in [validation history](../../../docs/validation/Validation-History.md).
