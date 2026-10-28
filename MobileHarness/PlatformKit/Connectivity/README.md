# Connectivity — Native links and network-path facts

## Responsibilities and boundaries

ConnectivityContainer owns NexArm USB/BLE capability instances and passive IP path observations. It uses system frameworks only. It defines no gesture catalog, Agent/Task policy, recovery decision, provider selection or application presentation. Callers own command meaning and physical completion.

[NexArm](NexArm/README.md) owns device position/parameter limits, update/write cadence, framing, protocol values, native session fencing and USB/CoreBluetooth observations. Discrete operations reject excess work; live writes report actual admission and never replay failed commands. Connection or subscription does not establish motor arrival or pose success.

## Network observation

NativeNetworkState owns one NWPathMonitor and one serial callback queue. start creates a fresh UUID generation and an unknown snapshot, then subscribes without an endpoint request, device scan or permission prompt. Each callback atomically replaces one value containing status, sorted interface types, expensive/constrained flags and observedAt. No queue of historical paths or per-event Task is retained. Before the first event flags/time are null and status is unknown.

Invalidation clears the generation/value before cancelling the monitor. stop also drains callbacks already queued on the serial queue; a late callback cannot update a retired or replacement generation. App foreground resume starts a fresh monitor after cleanup. This observer is part of PlatformContainer lifetime and independent of UI page lifetime. No path update emits a Signal or starts an inference.

The snapshot describes a path, not endpoint availability, request success, bandwidth or exact network charges. It excludes interface names, addresses, SSIDs and device identifiers. PlatformContainer exposes it through its finite native State port only while admission is open.

## Authorization and failure

Bluetooth authorization uses the static CBManager query. State reads do not create a central manager, scan or connect; actual link operations remain explicitly requested. Permission states are not Agent/Skill authority. Native enum additions map to unknown. stop closes owned USB/BLE links and verifies disconnection, retaining real cleanup failures through PlatformFailure.

[PlatformKit](../README.md) · [NexArm protocol](NexArm/README.md)

NexArm通用设备参数、允许误差、位置反馈观察、经验行程估算与原生恢复分类/预算由 PlatformKit 拥有；Actions 仅消费这些能力并拥有动作目标、资源、执行报告、设备选择及业务生命周期协调。硬件错误保持SDK类型，上层仅适配展示与动作结果，基础模块不依赖业务模块。
