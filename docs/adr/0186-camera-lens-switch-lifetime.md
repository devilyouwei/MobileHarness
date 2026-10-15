# ADR0186 — Separate lens switching from perception retirement

Date: 2026-10-08. Status: implemented; physical latency acceptance pending.

The previous CameraCoordinator flip invalidated presentation, released the capture lease, stopped AVCaptureSession, joined VisionSession inference/tracking cleanup and acquired/restarted capture. Consequently a native lens change inherited unrelated model/Agent teardown latency.

Healthy flips now keep the capture lease, renewal owner, preview session and outputs. PlatformKit AppleCamera.switchCamera validates authorization/running state/no active photo, prepares a replacement video input and commits input replacement on its actor. It drains the serial frame queue, closes the old bounded stream and creates a fresh stream. Configuration rejection restores the previous input when admissible; the host surfaces failure and performs full cleanup. No healthy flip calls stopRunning/startRunning.

App CameraCoordinator immediately invalidates old pose/gaze/session identity, fences native acknowledgment by foreground and revision, then completes the command after confirmed native running state. Root-owned CameraVisionRestartWorkflow holds one active/retiring task, one replacement worker and one replaceable pending intent. New intents cancel old work and replace pending intent; startup waits for joined endpoint/Agent cleanup, without delaying native acknowledgment. Stop/background/model maintenance invalidate and join retirement; stale startup is rejected. Fast repeated flips coalesce pending perception intents, with no overlapping endpoint owners. UI/model camera requests still pass through Photographer and canonical Actions.

Native input switching uses [AVCaptureSession configuration transactions](https://developer.apple.com/documentation/avfoundation/avcapturesession/beginconfiguration()). Sensor reconfiguration and first-frame delivery still have hardware latency; this decision does not promise zero delay. Native acknowledgment duration is logged for later device measurement.

Injected gate-based regressions verify nonblocking replacement, latest-intent coalescing and shutdown rejection/joining. Native touch, repeated inference-time flips and voice coexistence require physical-device acceptance. Build and check results belong to [Validation history](../validation/Validation-History.md).
