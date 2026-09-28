# ADR 0053: Settings and immediate chat selection

Accepted 2026-09-28. Supersedes ADR 0051's restart-only configuration limitation.

The home top-right primary controls are camera and settings. Lens/threshold actions appear in a secondary row only while the camera is enabled. Settings is accessible independently of voice startup.

The user enters URL and Key, explicitly loads GET /models, selects a model, then saves. No arbitrary cloud model is selected automatically. Model discovery is bounded and never generates a chat response. URL/key changes invalidate the list. App stores URL, Key and model together in a device-only Keychain item; no secrets in UserDefaults, Agent JSON or logs. Disabling the cloud switch and saving restores local generation while preserving credentials.

App stops and joins the current voice round before saving. Defaults performs an assembly-only replacement of the chat registration while keeping the single process manager and other providers. Candidate construction failure preserves the old registration; successful replacement cancels/joins old model work, closes old handles and retains the default ID. Existing Agent consumers receive an App forwarding capability that resolves the current binding for every call. No Agent code or Gateway contract changes.

Settings persists before replacement and restores the previous stored configuration if replacement fails; persistence rollback errors are reported explicitly. Startup restores configuration before model warmup. No live automatic fallback/retry or chat-capability claim is made just because a provider lists a model.

✅ Explicit discovery, selection, storage and runtime reconfiguration.
❌ Live provider credentials, real phone layout and continuous audio/camera behavior require device acceptance.

Validation (2026-09-28): root scripts/check.sh passed, followed by all nine OpenAIChatTests after the final discovery case was added. scripts/build-ios.sh passed all four simulator schemes. The simulator App installed and launched. Computer-use access to Device Hub timed out, so toolbar placement, settings interactions and animation have not been visually accepted. No real cloud credentials or live chat request were used.

Update: settings is a standalone navigation destination containing a feature list and a second-level cloud form. A persisted enabled flag independently selects cloud/local; disabling retains URL/key/model. Legacy records decode enabled=true. Native PasteButton provides user-initiated text paste. Window-root camera observation and conversation run tasks survive navigation; settings entry stops voice and suspends camera, and return restores camera intent.

Two-level navigation update validation: scripts/check.sh and all four scripts/build-ios.sh simulator schemes passed. Device visual, navigation and clipboard interaction acceptance remains pending.
