# Delivery roadmap

## Implemented foundation

| Area | Delivered scope |
| --- | --- |
| Agent runtime | Five business Agents, JSON v5 permissions, static communication and independent AgentCore. |
| Processing | Local speech/chat/pose capabilities, explicit cloud chat configuration and shared model management. |
| Behavior | Scheduled Actions, direct Tools, nested wait, result feedback and declared-resource coordination. |
| Host | Independent UI, role-specific lifecycle dependencies, six feature workflows and typed App adapters. |
| Data | Persistent settings/conversation history and reply-owned transient PCM. |
| Devices | Foreground camera/audio and NexArm connection, native feedback and shared Action bindings. |

Current contracts and dependencies live in the [technical design](../MobileHarness/README.md); implementation history is retained in [Milestone-History](Milestone-History.md).

## Acceptance work

- Record sustained iPhone Chinese/English conversation, listening quality, synthesis quality, first-audio latency, interruptions/route changes, memory and thermal behavior using [Voice](Voice.md) and [MOSS validation](Moss-Validation.md).
- Validate real cloud providers, switching and failure recovery separately from offline adapter tests.
- Extend supervised robot evidence to relevant BLE cadence, repeated operation, hardware/load configurations and recovery cases. Existing trial results are scoped to their recorded environment in [physical acceptance](NexArm_Physical_Acceptance.md) and [measurements](measurements/README.md).
- Validate current streaming/wait/cancellation behavior under real model output and device playback/presentation.

## Future implementation directions

| Direction | Boundary before implementation |
| --- | --- |
| Additional media/semantic memory | Concrete consumers, retention/privacy/deletion and capacity policy. |
| Richer model capabilities | Typed capability, real adapter need and explicit unsupported behavior. |
| Local native Tool events and result-driven request/reply | Transport schemas, permission/identity, cancellation and feedback ownership. |
| Fast/slow cognition and compute routing | Explicit Agent roles and capability availability/resource policy. |
| Activity supervision and multi-window ownership | Named lifetime/resource owners and isolated state routing. |
| Photographer motion | User task, native device capabilities, bounded motion, feedback and device-side protection; see [proposal](Photographer-Proposal.md). |

No delivery dates or physical safety certification are implied. Requirements belong to [Requirements](Requirements.md), experimental results to evidence documents, and architecture decisions to [ADRs](adr/README.md).

- Camera.open/close/flip Tools are registered and declared in Assistant JSON; physical camera/lens/permission acceptance and native model Tool event transport remain pending.

✅ Shared-pose Photographer and five-axis Robot.aim BLE dispatch are implemented. ❌ Physical tracking, wrist recovery and Wi-Fi control acceptance remain pending.

✅ Tracking implementation audit covers Tool resource declarations, composition-owned Agent factories, partial registration cleanup, payload validation, bounded output overflow and latched write failure. ❌ Real-device tracking accuracy and physical stop/arrival acceptance remain pending.

❌ Investigate the reported iPhone NexArm reply timeout after branch merge. Structured query/notification diagnostics are implemented; the physical failure cause is not yet established.

✅ Offline-robot tracking isolation, BLE connected/control-unready presentation and incremental Agent-resource refresh are implemented. ❌ Phone acceptance must verify pose display with an offline arm, query-timeout state and tracking after reconnect.

✅ Implemented: producer messaging failure isolation, completion Tool error results and Photographer control-availability gating. Outstanding: sustained iPhone disconnect/reconnect and voice-service failure acceptance.

✅ Integrated latest feat/main-sh incremental Photographer tracking into main’s current Action/Tool boundaries; retained Agent isolation and Bluetooth control-readiness contracts. ❌ Hardware smoothness and disconnect/reconnect tracking acceptance remain pending.

✅ Finite expression performance and persistent base state are separated; offline tests validate scheduler and cleanup contracts. ❌ iPhone acceptance must cover consecutive same/different expressions, wait ordering, Reduce Motion, hidden/background rendering, next-turn cancellation and base restoration.

## Local model resource management

✅ Declarative source metadata, ModelKitHub SDK adapter, receipt-based installation, Settings source controls and safe removal are implemented. ❌ HF durable background/partial resume, batch acquisition and physical-device acceptance remain. See [Management](../MobileHarness/ModelKit/Management/README.md#local-model-resources--current-contract) and [ADR0105](adr/0105-local-model-resource-management.md).

✅ Native Tool call history and input/generated/total token diagnostics are implemented in the existing Settings history flow, with backward-compatible optional records and actual Gateway execution outcomes. ❌ Physical Camera/provider usage/UI acceptance and partial native-stream diagnostics remain pending.

✅ Local model resource first release: metadata-only packaging, bounded verified download/installation, persistent official/mirror/custom source settings, explicit stop-and-delete and sandbox-only loading. ❌ Full iOS build/device acceptance, partial-file resumeData, batch download, orphan-staging collection and derived compilation-byte accounting remain. See Management current contract for proposal deviations.

Validation (2026-10-03): 35 isolated shared tests passed (32 ModelKitRuntime, 2 Storage, 1 Settings), using the same root sources through temporary symlink target selection to avoid unrelated MLX Metal compilation. ModelKitHub/ModelKitRuntime builds and Defaults/App adapter type checks passed; device/simulator staging fixtures contain only metadata/licenses and remove stale weights. Boundary, provisioning tests, Swift formatting and project plist checks passed. Full check.sh stops at missing `metal`; build-ios.sh requires full Xcode, currently only Command Line Tools selected. iOS UI/delegate runtime and physical inference/background acceptance remain unverified.

✅ Local-resource refinement: compact schema-v2 repository/selection declarations replace per-file links/hashes. ModelKitHub wraps swift-huggingface 0.9.0 outside Management; App injects it. Storage-backed receipts record actual installed files/sizes. ✅ HF native background transfers preserve generations/completed files and available resume data. ❌ Full iPhone/server-resume acceptance remains pending (ADR 0108). See [ADR0105](adr/0105-local-model-resource-management.md).

✅ Model artifact completion preserves receipt-validated installed state after task-index write failure; atomic transfer snapshots remove split load/save races. ❌ Real iPhone YOLO incident attribution and lock-state/network/UI acceptance remain pending device access.

✅ Real YOLO archive plus production App storage probe reproduces and fixes shifted receipt paths across filesystem aliases; exact known-bug receipts repair without re-downloading valid files. ❌ Physical iPhone confirmation remains pending connectivity.


✅ Replaced Nemotron CoreAI exports with the shared multilingual 2240 ms Core ML catalog and bounded FluidAudio adapter. ❌ Complete phone English/Chinese quality, cancellation, sustained thermal/memory and end-to-end latency acceptance for this export.


✅ HF model background transport, preserved completed files, system resume-data reuse, bounded retries and three concurrent files/package implemented. ❌ Validate physical-phone lock-screen, system termination, forced quit, signed-URL expiry and large-file resume/speed with actual network traces.
