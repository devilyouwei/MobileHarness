# Connectivity — Native links and network-path facts

## Responsibilities and boundaries

ConnectivityContainer owns NexArm USB/BLE capability instances and passive IP path observations. It uses system frameworks only. It defines no gesture catalog, Agent/Task policy, recovery decision, provider selection or application presentation. Callers own command meaning and physical completion.

[NexArm](NexArm/README.md) owns device position/parameter limits, update/write cadence, framing, protocol values, native session fencing and USB/CoreBluetooth observations. Discrete operations reject excess work; live writes report actual admission and never replay failed commands. Connection or subscription does not establish motor arrival or pose success.

## Network observation

NativeNetworkState owns one NWPathMonitor and one serial callback queue. start creates a fresh UUID generation and an unknown snapshot, then subscribes without an endpoint request, device scan or permission prompt. Each callback atomically replaces one value containing status, sorted interface types, expensive/constrained flags and observedAt. No queue of historical paths or per-event Task is retained. Before the first event flags/time are null and status is unknown.

Invalidation clears the generation/value before cancelling the monitor. stop also drains callbacks already queued on the serial queue; a late callback cannot update a retired or replacement generation. App foreground resume starts a fresh monitor after cleanup. This observer is part of PlatformContainer lifetime and independent of UI page lifetime. No path update emits a Signal or starts an inference.

The snapshot describes a path, not endpoint availability, request success, bandwidth or exact network charges. It excludes interface names, addresses, SSIDs and device identifiers. PlatformContainer exposes it through its finite native State port only while admission is open.

## Authorization and failure

The collector seeds Bluetooth authorization using the static CBManager query and refreshes it on native power changes and foreground resume. Container State reads only the stored permission value. State reads do not create a central manager, scan or connect; actual link operations remain explicitly requested. Permission states are not Agent/Skill authority. Native enum additions map to unknown. stop closes owned USB/BLE links and verifies disconnection, retaining real cleanup failures through PlatformFailure.

[PlatformKit](../README.md) · [NexArm protocol](NexArm/README.md)

NexArm通用设备参数、允许误差、位置反馈观察、经验行程估算与原生恢复分类/预算由 PlatformKit 拥有；Actions 仅消费这些能力并拥有动作目标、资源、执行报告、设备选择及业务生命周期协调。硬件错误保持SDK类型，上层仅适配展示与动作结果，基础模块不依赖业务模块。

## Passive state observation

The owning stateSnapshot entry point reads current local business/capability values and runtime admission/work facts in the owner's isolation domain. It performs no action, acquisition or device activation. The module root composes the explicitly selected fields; unknown diagnostic coverage is not healthy evidence. Domain-specific completion and failure contracts above remain authoritative.

State classifies native connection/power/scanning and measured joint positions/freshness as Business. Session identity/revision, watchdog and query quarantine are Runtime.

Business.problem=positionFeedbackUnavailable requires connected-session missing or stale position evidence. A query quarantine/watchdog limitation can affect engineering health and control policy without asserting loss of existing fresh feedback. Native issues use connection-integrity wording, without upper-layer robot-control policy.

The connectivity Container snapshot contains its own authorization/admission and a native-link index. Link and each motor have separate exact reader capabilities; reading an axis never builds link or sibling snapshots. All declared indices are metadata, not evidence of connected hardware.


Native BLE reflection reads the existing resident NexArmBluetoothState reference. Each native publish replaces its single memory value before yielding to the original business event stream. Reflection has no subscriber that can steal business events and no query, driver construction or active feedback probe. Initial disconnected describes the actual absence of a connection; power/positions stay unknown until observed. Optional adapters without a resident State reference expose unknown. Recorded receipt age/freshness is a pure monotonic calculation and never triggers native I/O.

Permission State projections read cached observations only. Unavailable owner scope remains unknown; an admitted cached-source/schema failure propagates through the standard throwing snapshot method instead of being converted to unknown.
