# Readable preview references and merged multimodal input

2026-11-06 user request: model-visible preview IDs must be preview_1, preview_2, …; combine selected State images with the actual user input message, retaining image metadata in system State. Persistent album IDs remain independently allocated.

## Implementation plan

- Storage Media/SQLite owns durable monotonic preview-number allocation using a namespaced sqlite_sequence entry. Allocate only an integer counter, no image record/file or schema migration. IDs never restart/reuse after cancellation, eviction, save or app restart; failed capture may leave a gap. Existing media_N allocation remains separate. Propagate allocation/capacity/closed failures.
- StorageCache.PreviewImageCache accepts a caller-supplied bounded identity instead of generating a UUID. CameraPreviewStore reserves asynchronously using the injected allocator, gates overlapping preparation/disposition/reservation and fences late allocation on shutdown/reset; native capture reserves before final geometry sampling/shutter so the allocation await cannot stale capture rotation. Tests inject explicit memory allocators.
- Camera's PreviewImageID accepts only canonical positive Int64 suffixes for live Actions/UI/State. Retain UUID preview parsing only on the history read route so existing saved images/history remain readable; newly generated State/Action receipts never use UUID preview IDs. Existing persisted owner association remains camera/album/previewID.
- Shared Chat request projection attaches fresh State images to the original current user-input message (preserving its text), including Action/native Tool continuations. No synthetic image-only user message or source/dimension prose is appended. Keep native call/result groups intact and preserve current intent/results during trimming.
- A system State image manifest identifies each attachment's position within that user message, ID, source, MIME, dimensions and byte count, or explicitly reports unsupported image delivery. This supplies the association because provider image blocks do not themselves carry ChatImage.id. Request-local images stay out of accumulated history/continuation bases and durable binary logs.
- Update Photography examples/revision, all live reference fixtures, shared request/State contracts and history compatibility documentation. No new directories, modules or dependencies.

## Validation

Test canonical numeric parsing/rejection, ordered allocation across concurrent calls and database reopen (including cancelled/unsaved identities), independent saved media IDs, cache duplicate rejection, late allocation closure/cancellation, history numeric and legacy references, merged original-user images in next-turn/Action/native continuations, system-only metadata and attachment order, unsupported models, request budgets and ephemeral audit. Run check.sh and build-ios.sh; build/install the current fix on the paired iPhone with existing signing when available. Separate install/launch evidence from native UI and real-model acceptance.

## Delivery

Implemented 2026-11-06. Numeric preview allocation, history compatibility, merged original-user attachments, system metadata mapping and Photography v39 are complete. Current technical READMEs describe the implemented ownership and lifecycle.

Main integration 1066 tests and LiveRuntimeTests 227 tests explicitly pass; four Simulator builds and the signed 2026110608 device package pass. The full check command exits 0 but a native macOS window visibility test logs a failure without a suite completion; isolated repetition also lacks a completion record, so native acceptance is not claimed. The paired phone is unavailable and installation failed with CoreDeviceError 4016. Installation was conditional on availability; no device update or native/real-model acceptance is claimed. See [validation evidence](../validation/Readable-Preview-Context.md) for failures and remaining independent acceptance limits.

Follow-up on 2026-11-06: the user requested installation after reconnecting the iPhone. Build 2026110608 was installed in place, independently read back and launched successfully. Actual UI/model acceptance remains with the user; see the appended validation evidence.
