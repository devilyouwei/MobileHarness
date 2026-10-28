# PlatformKit — Native capabilities and system facts

## Responsibilities and boundaries

PlatformKit is an independent foundation SDK using system frameworks only. It owns native audio, camera, connectivity, typed observations, platform admission, native errors and passive system facts. It imports no Agent, Gateway, Actions, UI, Storage, ModelKit or application composition code. App constructs its single scoped root and controls lifetime; business consent, resource arbitration, interpretation and execution policy remain above the SDK.

## Public relationships and components

| Component | Capabilities and owner |
| --- | --- |
| PlatformContainer | Root admission, lifecycle/failure projection and the finite PlatformStateReading port. Constructor creates capabilities without starting observations or devices. |
| [Core](Core/README.md) | Native background allowance, bounded observation primitives, finite State source contract and system time/power/thermal/locale/accessibility reads. |
| [Audio](Audio/README.md) | Native capture/playback, cues/haptics, numerical processing, native session events and application audio/permission facts. |
| [Vision](Vision/README.md) | Camera/immutable frames/photo access and image preparation; camera/Photos authorization queries. |
| [Connectivity](Connectivity/README.md) | NexArm device constraints and bounded USB/BLE writes, protocol values, connection observations, passive IP path monitoring and Bluetooth authorization queries. |

Native observation capabilities are injected directly into their responsible Agent or execution owner. They never generate business Signals. Read-only capture subscription does not start hardware; capture control stays with its owner. PCM remains ordered and bounded, while camera/native state observations retain newest values under the owning contracts.

## Native State port

PlatformStateSource has eight cases: time, power, thermal, network, permissions, audio, locale and accessibility. PlatformStateReading.snapshot returns one bounded JSON object for the selected source. It has no model-context envelope, role identity, Task or Skill semantics. App injects this narrow port into Agents; Agents supplies the platform.* source names and availability/value envelope. The [overall State flow](../README.md#container-state-read-path) describes that adapter and request sampling.

System time is sampled to seconds with a Gregorian date, fixed English weekday, current time-zone identifier and UTC offset. Power exposes battery level/charge/Low Power Mode; thermal exposes the OS pressure enum. Locale exposes locale/language/region identifiers, not physical location. Accessibility exposes VoiceOver, reduced motion, captions and mono audio. Permissions combine camera, microphone, Photos add-only/read-write and Bluetooth query results. Audio exposes port types, input mute and observed interruption; network exposes current path properties and last observation time. No device names, route UIDs, SSIDs, IPs, credentials or sensor streams are included.

Unknown native readings remain unknown/null. A denied permission is a successfully observed native condition, not a read error or business grant. Network path satisfaction is not evidence of endpoint success. The root rejects reads while cold, suspended or stopped and bounds each source to 8 KiB. OS/platform errors remain explicit rather than returning fabricated success.

## Root lifetime, observation and cleanup

start opens admission and starts passive battery/network/audio-event observation. It does not request permissions, open capture/playback, scan Bluetooth or probe a network endpoint. Battery monitoring restores its previous setting on invalidation. Audio retains two synchronous notification observers and a generation-fenced optional interruption fact. Network owns one monitor, one serial callback queue and one latest value; invalidation clears the generation before cancellation. Cleanup drains already queued callbacks; late generations cannot publish into a replacement.

invalidate closes admission synchronously, fences passive observations and requests native shutdown. setForeground(false) joins that cleanup; resume starts fresh observations only after the old cleanup succeeds and its foreground revision still matches. A newer invalidation prevents a late resume from reopening admission. Repeated stop shares the same joined result and retains cleanup failures. A stopped root cannot reopen. No observation event creates a model decision or executes business work.

Audio/Vision/Connectivity own their native stop/join semantics; short background allowance only assists cleanup/reassociation and cannot guarantee background inference or physical safety. Physical completion remains evidence supplied by the actual device owner. Detailed limits, cancellation and native failures belong in each component README.

[Overall design](../README.md) · [App composition](../App/Composition/README.md)

NexArm通用设备参数、允许误差、位置反馈观察、经验行程估算与原生恢复分类/预算由 PlatformKit 拥有；Actions 仅消费这些能力并拥有动作目标、资源、执行报告、设备选择及业务生命周期协调。硬件错误保持SDK类型，上层仅适配展示与动作结果，基础模块不依赖业务模块。
