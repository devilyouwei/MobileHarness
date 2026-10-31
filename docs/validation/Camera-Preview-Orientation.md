# Camera preview orientation validation

## Report and diagnosis — 2026-10-31

The user reported that physically rotating the phone left a portrait person enlarged into the center of the camera background. The supplied private screenshot is evidence for the report, not a committed test asset. The user explicitly selected portrait UI with naturally rotating preview, rather than enabling full-app landscape.

Source diagnosis: the iPhone target permits portrait interface orientation only. AppleCamera publishes gravity-upright frame rotation/size from RotationCoordinator.videoRotationAngleForHorizonLevelCapture; the Metal renderer previously aspect-filled those dimensions directly into the interface viewport. A gravity rotation changed 180×320 to 320×180 while the viewport stayed 180×320: the old layout used a 1.778 scale and sampled only about 31.6% of the image width. Preview/capture orientation were being treated as the same coordinate system. This is a crop change, without an intentional camera zoom command.

## Implemented contract

PlatformKit records a static sensor-to-portrait reference from the active camera during graph configuration on iOS 27. It publishes optional portraitRotation atomically with the existing source-frame rotation, dimensions and generation. Source orientation/gray sampling and JPEG capture retain their original gravity-based contracts. Older SDK clients without the static native API keep a nil reference and their original supplied-upright behavior; the full app requires iOS 27.

Actions forwards the reference into CameraVideoFrame. UI CameraPreviewBasis/CameraPreviewGeometry combine it with actual UIWindowScene interface orientation, sharing display dimensions/crop between the Metal image and skeleton. Mirroring occurs in display coordinates. The existing already-mirrored attention vector is converted into those same display axes. Ordinary video updates do not invalidate gaze presentation when its small orientation basis stays unchanged.

Mailbox equality and mesh cache keys include interface orientation and sensor reference. A changed reference clears old skeletons and rejects mismatched attachments. Interface reports use one coalesced view-owned task outside the representable update transaction, with view epoch plus CameraState source-generation/stopped checks. Detach/replacement cancels the task. The iPhone portrait policy, capture session/lease ownership, photo direction, model input, 750 ms media freshness and native cleanup remain unchanged. No new module, directory, dependency, pixel copy or per-frame task was introduced.

## Automated checks and build evidence

Asymmetric synthetic sensor geometry covers all capture/interface quarter-turn combinations, front/back mirroring, portrait-locked crop invariance, nonmatching viewport crop, known pixel/pose coordinates, gaze axes, nil-reference compatibility, orientation-only mailbox/mesh invalidation, invalid metadata and stale sensor attachments. Observation tracking checks no gaze invalidation from a newer same-basis video. Owner-generation regression rejects retired/stopped interface reports. Existing grayscale orientation tests cover the unchanged inference sampling.

Focused verification passed 13 UI tests plus two native-sampling integration tests before the final interface-report generation regression, which is covered by the complete check below. Initial development compilation caught a new initializer declaration and Swift Testing expansion of a mutating mailbox call; both were corrected. No production fallback or timing assertion was weakened to pass tests.

The first complete check was run concurrently with Xcode builds. Its regular IntegrationTests phase had one existing NativeStateCollection notification-recovery fixture timeout (3.507 s); the unrelated State collector code was unchanged. That check was stopped during its later isolated phase. The complete check was then rerun after all builds had finished, preserving the original timeout and assertions. Final results follow below.

All four final Simulator build schemes succeeded. The first device-target build command could not find the disconnected iPhone destination; the subsequent generic iOS signed MobileHarness build succeeded. Bundle Agent/Skill verification passed (25 assets), and codesign verification passed. These results establish compilation and synthetic/native-host behavior, not physical rotation correctness.

## Device follow-up

At build time, the previously paired iPhone 17 Pro was unavailable. Requested USB connection/unlock while independent verification continued. Installation and physical acceptance are recorded below when performed. Required physical checks: portrait/left/right phone rotation with UI remaining portrait, front/back lens switching, skeleton alignment, gaze direction, simultaneous voice operation, JPEG direction and foreground resume. Do not equate an installed build with those checks passing.

## Final verification

The standalone rerun of ./scripts/check.sh exited 0: architecture/source ownership, six Python tests, strict Swift formatting, all Swift phases and plist validation passed. Regular UITests passed 125 tests (0.476 s); regular IntegrationTests passed 923 (64.598 s); isolated LiveRuntimeTests passed 225 (205.130 s). The earlier notification-recovery fixture passed unchanged in 1.649 s. The final owner-generation and sensor-reference/gaze observation regressions are included. No unresolved automated failure remains.

./scripts/build-ios.sh exited 0 for MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero. The final signed generic-device MobileHarness build also exited 0, including the iOS-only rotation API, interface callback and renderer code. Agent/Skill resources and codesign verification passed. Seven affected design/plan documents and 134 local link targets passed path validation; git diff formatting passed. Logs: /tmp/mobileharness-camera-orientation-check-final.log, /tmp/mobileharness-camera-orientation-build-final.log and /tmp/mobileharness-camera-orientation-device-build-final.log.

At the end of the build/check run, device discovery reported the iPhone 17 Pro unavailable, so installation initially remained pending. The signed bundle was ready at build/DeviceDerivedData/Build/Products/Debug-iphoneos/MobileHarness.app. No screenshot or synthetic fixture result is represented as physical-device acceptance. The subsequent installation is recorded below.


## Device installation follow-up

After the user requested installation with the iPhone available again, the signed repair bundle installed successfully on the physical iPhone 17 Pro. devicectl exited 0 and its structured installation outcome was success; a subsequent device app query confirmed dev.mobileharness.app (0.1.0 / build 1). Evidence: /tmp/mobileharness-camera-orientation-install.json and /tmp/mobileharness-camera-orientation-installed.json. This completes installation only. No application launch, physical portrait/left/right rotation, lens/photo/voice/resume acceptance or screenshot capture was performed during installation.


## User-confirmed device result — 2026-10-31

After installation, the user confirmed: “好了，已经修复了”. This records user acceptance that the originally reported physical-phone rotation/person orientation and enlargement defect is resolved on the installed repair. It is user-reported device evidence, not an assistant-observed camera session. Separate left/right, lens switching, skeleton/gaze alignment, JPEG, voice coexistence and resume matrix results were not individually reported; this confirmation does not mark that broader matrix complete.
