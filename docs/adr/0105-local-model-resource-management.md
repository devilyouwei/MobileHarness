# ADR0105 — Explicit local model resource management

Status: Accepted, revised 2026-10-03.

## Context

Weights must not be bundled. Settings needs explicit acquisition/removal while ModelKit remains an independent capability SDK. Hand-maintained per-file links/sizes/hashes duplicate Hub metadata and make catalog updates expensive. hugging-mac uses source declarations and a separate SDK downloader; this implementation follows that separation.

## Decision

Management retains its ModelKit-only dependency and owns ModelArtifactStore, provider artifact associations, bounded scheduling and safe installation/removal. ModelRegistration owns compact schema-v2 source/required-file contracts and injected downloader/storage protocols. A concrete ModelKitHub backend adapter uses official swift-huggingface 0.9.0 and is injected by App through Defaults. This single independent adapter target replaces the prior no-new-target constraint to preserve SDK dependency direction. Storage stays generic; App writes actual local installation receipts. UI receives only presentation values/operations.

HF declarations contain repoId, selected patterns, optional revision/prefix. Tested graph exports keep one source revision; no per-file URL/hash/size catalog is bundled. Archive sources retain optional archive hash verification. License identity remains metadata. Hub handles remote resolution/metadata; required files and bounded local trees are checked before atomic publication. Installed receipts contain actual sizes. Download estimates are advisory.

## Consequences

HF metadata is resolved with the SDK; native background sessions download up to three files/package with endpoint/cellular policy and no permanent SDK blob cache (updated by ADR 0108). Two packages/eight pending requests are admitted; overflow rejects. Page navigation does not cancel work. Persisted HF requests preserve generation/staging on relaunch; native tasks, completed files and available resume data are reused. Server resume and physical-phone acceptance remain conditional. ZIP transport keeps its existing background reassociation. SDK verification is not an independent static hash trust anchor. ModelManager maintenance prevents retained handles from reloading while App quiesces/drains/unloads and removes files. Missing weights never block Settings/history. Device/network/background acceptance remains outstanding.

Implementation refinement (2026-10-03): swift-huggingface 0.9.0 snapshot downloads include directory entries and require a cache at completion. ModelKitHub now uses Hub listFiles plus selected regular-file downloadFile calls without a persistent SDK cache. It samples per-file byte progress and aggregates using remote file sizes. Settings shows connection waiting before bytes arrive and one-decimal progress thereafter. Both official and HF-Mirror production-adapter macOS downloads pass; real iPhone UI acceptance remains separate.

Completion refinement (2026-10-03): an installed receipt is authoritative for settled installation status; persisting transfer bookkeeping is a separate outcome and cannot turn committed files into a download failure. App saves complete transfer snapshots atomically using generic Storage last-writer-wins replacement and afterFirstUnlock protection. Other document clients retain compare-and-save and whileUnlocked defaults. Phone-specific YOLO failure causation remains unconfirmed without device records.

Receipt refinement (2026-10-03): native directory enumeration may return /private/var child URLs while the stage URL uses /var. Subtracting the unnormalized stage string length corrupted every recorded relative path, causing a published model to fail receipt validation. App now derives confined relative paths via Storage normalization. Only receipts matching the exact former seven-hex-digit staging-prefix shape are repaired, after existing identity/revision and full file-size/path validation; other malformed receipts retain explicit deletion repair. The full actual YOLO archive/production adapter path is verified on macOS; phone confirmation remains separate.
