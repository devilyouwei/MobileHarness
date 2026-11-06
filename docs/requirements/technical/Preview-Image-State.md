# Preview image cache and multimodal State

Accepted scope (2026-11-06): implement the approved three-layer design. Capture publishes only to bounded Storage memory; Camera owns default latest image and up to three explicitly selected images per context; explicit save publishes original bytes into the persistent album. Ignore removes preview bytes and every selection. New conversations reset explicit selections but preserve cache/latest; Skill absence hides attachments without destroying selections. App album reads and existing web screenshot behavior are outside this migration.

## Ownership and interfaces

- Storage/Cache: immutable preview entries, reservations, FIFO eviction of unpinned entries, leases and byte/count bounds (8 originals/32MiB, original <=4MiB). No Camera/Agent policy.
- Actions/Camera and shared contracts: previewID distinct from persisted mediaID, Camera-owned publication/selection, loadPreviewImage/unloadPreviewImage, ID-addressed save/ignore, joined cancellation and error outcomes. Analysis JPEG retains existing1568px/1MP/1MiB policy. Camera preview State has metadata plus typed ephemeral attachments; UI observes only its selected display identity.
- Agents/Support/Core, Context and Chat: typed multimodal snapshots; read only Skill-selected sources every request, replace transient attachments rather than accumulate historical images, maintain complete call/result groups and current-input protection. Ephemeral attachments are metadata-only in model-request logs. Assistant's camera-result special case is removed; web observation remains.
- App/Composition, Actions and Agents ports: inject the common cache and scope-aware snapshot/reset ports without cross-module implementation imports. UI/Camera and Photographer migrate temporary IDs; persistent album identities remain unchanged.

## Failure/lifecycle

State changes never initiate inference. Only model calls may trigger feedback. Read/load capacity failures are explicit, no silent selection replacement. Save failure preserves original/selection; committed save is not undone by presentation failure. Ignore/save invalidate racing loads. Captured original remains available when analysis preparation or display fails. New input retains state; new conversation releases explicit pins. Closing root joins calls and releases preview cache; process restart loses unsaved images. No preview image bytes in files or diagnostic database logs. Existing files/logs are not destructively migrated.

## Validation and documentation

Add behavioral cache, selection, concurrent invalidation, cross-turn Skill-scoped attachments, request-log redaction, save/discard and capacity tests. Run scripts/check.sh and scripts/build-ios.sh; distinguish stub model/native builds from real-model/iPhone acceptance. Update owning Storage, Actions/Camera/contracts, Agents/Context/Chat/Assistant/Photographer, UI/Camera, Resources/Skills, App/Composition READMEs and overall design after implementation. No new directories/modules/dependencies.

Implementation and validation pending.
