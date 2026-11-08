# Preview image references in conversation history

2026-11-06 regression: the history page rejects preview_UUID references as invalid media_N IDs before reading, and the full-read binding only reads persisted Assistant media. Model requests correctly include Camera State images, but the detail page renders retry instead of the image.

## Intended fix and ownership

- Actions/History/ConversationHistoryWorkflow.swift accepts both typed preview IDs and persistent media IDs after validating the exact attachment in the selected recorded request. Keep original-input identity, four-read admission, cancellation and byte limits. A missing ephemeral image is an explicit expired outcome; persistent image read failures keep existing retry semantics.
- Actions/Camera/CameraPreviewStore.swift exposes a read-only history-image accessor. Read an available original without loading/selecting it into State; otherwise use an injected saved-image reader. Closing rejects reads. The reader must not revive ignored/evicted photos, add State selections, write files or cause inference.
- Actions/Camera/CameraCoordinator.swift injects saved lookup by the existing exact camera/album/previewID StorageOwner. ActionsBusinessAssembly routes preview history references to this owner; legacy media IDs retain their original source/input check. No Assistant delegation or new model Action.
- Storage/Database/Media and SQLite add a bounded exact-owner lookup for ready collected images. Existing saved preview ownership provides a durable association without schema changes or extra image copies. Exclude uncollected, wrong-owner, deleted and video records. Reads remain within the existing operation gate and 4 MiB history bound.
- UI/Settings distinguishes released temporary images from retryable read/decode failures; retains the existing thumbnail and full-screen viewer lifecycle. A neutral image-view label covers original bytes shown from cache/album.

## Validation and documentation

Add regression for valid preview references and invalid attachments, cache-backed history reads across turns, read-only selection behavior, saved image recovery after cache/root replacement, owner isolation, deletion/expiry and failure propagation. Keep log redaction and no-unsaved-disk-write invariants. Run scripts/check.sh and scripts/build-ios.sh; build/install the fix on the available iPhone using the existing signing configuration. Update owning History/Camera/Storage Media/SQLite/UI Settings and overall/module READMEs, preserve historical evidence, and record actual device launch/acceptance separately. No new directories, modules, dependencies or schema migration.

## Delivery

Completed 2026-11-06. Both historical ID validation and the production read binding now support preview references. Live originals and saved originals resolve without modifying model State; released temporary images have an explicit UI outcome. No database schema or extra image persistence was added.

Targeted regressions, full check.sh, four iOS Simulator builds, signed device build and package validation passed. Build 2026110607 was installed and its version independently confirmed on iPhone 17 Pro after one transient connection retry. Launch was denied by device lock; native visual acceptance remains distinct and unverified. See [validation evidence](../validation/Preview-History-Images.md).
