# Camera background

Purpose: present an edge-to-edge live camera background behind the conversation. Design goals: legible existing content, independent camera controls and accessible failure recovery.

✅ CameraConversationSurface wraps both model startup and ready conversation so camera permission/preview do not wait for model loading. App owns CameraCoordinator. Preview uses resizeAspectFill, front-camera mirroring, natural rear-camera orientation and Apple's RotationCoordinator for horizon-level rotation.
✅ A 42% black overlay dims the preview. The preview and overlay ignore touches; the existing voice orb and captions remain above them. Off, inactive and unavailable states hide the preview over pure black. No previous frame remains visible after off.
✅ Top controls expose camera on/off and front/back switching, with 48-point targets, VoiceOver labels and accessibility identifiers. Camera failure offers retry or a Settings link after denied permission. Switching is disabled during a transition; on/off remains available and replaces pending intent.
❌ Recording and device visual/performance acceptance. Simulator unavailability is displayed explicitly, never replaced by a fake feed.

Validation (2026-09-26): root scripts/check.sh passed; all four scripts/build-ios.sh simulator schemes passed; the physical MobileHarness Debug target compiled without signing. Simulator launch confirmed camera controls render during model preparation and the system camera permission prompt appears. The simulator has no physical camera and lacks voice model resources, so live video, front/back switching, camera/voice coexistence and ready-conversation visual acceptance still require an iPhone. No physical device installation was performed.

✅ Skeleton overlay arrives only through UI.showPose. Green joints/edges require confidence ≥0.3. Upright coordinates are converted back to native sensor coordinates; AVCaptureVideoPreviewLayer conversion applies front mirroring, resizeAspectFill crop and current rotation. Rotation-mismatched overlays are hidden. Camera close/switch/background clears overlay immediately. Threshold menu selects 1/3/5/10% (default 3%); changing it replaces the capture/filter/Agent incarnation and retains model weights.

✅ Camera controls start 64 pt below the top safe area, leaving the centered reply spectrum unobstructed. Camera actions and permissions are unchanged.

✅ CameraConversationSurface injects the camera-owned normalized eyeGaze environment into startup and conversation content; front mirroring is handled once in perception. Lifecycle resets smoothly center gaze. ❌ Exact preview-crop projection is not used for the directional eye target.

✅ The primary toolbar sits 8 pt below the top safe area and contains camera toggle plus settings. Camera lens switching and threshold controls expand in a second row only while camera intent is enabled; closing camera removes them. Reduce Motion disables the expansion animation. ❌ Camera hardware behavior is unchanged.

✅ Camera observation is window-owned across page navigation. Settings suspends capture without changing on/off intent; returning to home resumes if enabled. ❌ Physical-device navigation/capture acceptance remains pending.
