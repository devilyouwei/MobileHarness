# PlatformKit — Native capabilities and system facts

## Responsibilities and boundaries

PlatformKit is an independent foundation SDK using system frameworks only. It owns native audio, camera, connectivity, typed observations, platform admission, native errors and passive system facts. It imports no Agent, Gateway, Actions, UI, Storage, ModelKit or application composition code. App constructs its single scoped root and controls lifetime; business consent, resource arbitration, interpretation and execution policy remain above the SDK.

## Public relationships and components

| Component | Capabilities and owner |
| --- | --- |
| PlatformContainer | Root admission, lifecycle/failure projection and the finite PlatformStateReading port. Constructor creates capabilities without starting observations or devices. |
| [Core](Core/README.md) | Native background allowance, bounded observation primitives, finite State source contract and system time/power/thermal/locale/accessibility reads. |
| [Audio](Audio/README.md) | Native capture/playback, cues/haptics, numerical processing, native session events and application audio/permission facts. |
| [Vision](Vision/README.md) | Camera/immutable frames/photo and audio-video file access, bounded media preparation; camera/Photos authorization queries. |
| [Connectivity](Connectivity/README.md) | NexArm device constraints and bounded USB/BLE writes, protocol values, connection observations, passive IP path monitoring and Bluetooth authorization queries. |

Native observation capabilities are injected directly into their responsible Agent or execution owner. They never generate business Signals. Read-only capture subscription does not start hardware; capture control stays with its owner. PCM remains ordered and bounded, while camera/native state observations retain newest values under the owning contracts.

## Native State port

PlatformStateSource has eight cases: time, power, thermal, network, permissions, audio, locale and accessibility. PlatformStateReading.snapshot returns one bounded JSON object for the selected source. It has no model-context envelope, role identity, Task or Skill semantics. Internal SDK callers can use this finite native port. Assistant selects platform.system.* Business attributes from exact classified State nodes through the App-bound inspector, and owns its availability/value envelope. The [overall State flow](../README.md#container-state-read-path) describes that adapter and resident State reads.

System time is sampled to seconds with a Gregorian date, fixed English weekday, current time-zone identifier and UTC offset. Power exposes battery level/charge/Low Power Mode; thermal exposes the OS pressure enum. Locale exposes locale/language/region identifiers, not physical location. Accessibility exposes VoiceOver, reduced motion, captions and mono audio. Permissions combine camera, microphone, Photos add-only/read-write and Bluetooth query results. Audio exposes port types, input mute and observed interruption; network exposes current path properties and last observation time. No device names, route UIDs, SSIDs, IPs, credentials or sensor streams are included.

Unknown native readings remain unknown/null. A denied permission is a successfully observed native condition, not a read error or business grant. Network path satisfaction is not evidence of endpoint success. The root rejects reads while cold, suspended or stopped and bounds each source to 8 KiB. OS/platform errors remain explicit rather than returning fabricated success.

## Root lifetime, observation and cleanup

start installs passive observation, synchronously seeds system/permission/audio facts into its resident State collection, and then opens admission. It does not request permissions, open capture/playback, scan Bluetooth or probe a network endpoint. Battery monitoring restores its previous setting on invalidation. Audio retains its generation-fenced optional interruption fact. The root subscribes to power/thermal/locale/accessibility/audio changes and permission-completion events before seeding; an owned one-second clock updates time without reader activity. Network owns one monitor, one serial callback queue and one latest value; invalidation clears the generation before cancellation. Cleanup drains already queued callbacks; late generations cannot publish into a replacement.

invalidate closes admission synchronously, clears resident source values, cancels its coalesced refresh worker/clock, fences passive observations and requests native shutdown. Cleanup joins the refresh worker. setForeground(false) joins that cleanup; resume starts fresh observations and reseeds current native values only after the old cleanup succeeds and its foreground revision still matches. A newer invalidation prevents a late resume from reopening admission. Repeated stop shares the same joined result and retains cleanup failures. A stopped root cannot reopen. No observation event creates a model decision or executes business work.

Audio/Vision/Connectivity own their native stop/join semantics; short background allowance only assists cleanup/reassociation and cannot guarantee background inference or physical safety. Physical completion remains evidence supplied by the actual device owner. Detailed limits, cancellation and native failures belong in each component README.

[Overall design](../README.md) · [App composition](../App/Composition/README.md)

NexArm通用设备参数、允许误差、位置反馈观察、经验行程估算与原生恢复分类/预算由 PlatformKit 拥有；Actions 仅消费这些能力并拥有动作目标、资源、执行报告、设备选择及业务生命周期协调。硬件错误保持SDK类型，上层仅适配展示与动作结果，基础模块不依赖业务模块。

## Reflexive state reads

`PlatformContainer.stateSnapshot() async throws` reads only root lifecycle/health and returns child indices. stateReaders() binds independent Audio/Vision/Connectivity/system/source/link/axis reads using module-local PlatformStateSnapshot. Catalog construction reads no native status or source values. Cold/stopped source nodes explicitly report unavailable without opening admission. Snapshots serialize resident values; they never invoke the native samplers. Runtime.collectionPhase distinguishes observing from awaitingFirstObservation for a network monitor without its first callback. Synchronous start does not claim that asynchronous device feedback has already arrived. Serious/critical thermal pressure is a limited capability, not inferred hardware damage. Root execution/cleanup failures are retained as faults. Collection time is separate from native observation age.

Connectivity reads the shared `NexArmBluetoothLink.reflectedState` resident reference. The native publisher updates it before publishing business events; inspection neither consumes that stream nor calls a native getter. Unsupported implementations expose nil; the native initial State records the actual absence of a connection, with unknown power and positions. Operational status() keeps its existing admission and lazy driver behavior. See [NexArm](Connectivity/NexArm/README.md) for positions and freshness.

The eight native source views live under platform.system; the capability container platform.audio remains separate. Skills explicitly select canonical platform.system.* paths.

Business contains native permissions, system/device conditions and measured motor positions with observation validity. Audio scope ownership/counts, lazy camera/import tasks, link generations/revisions, watchdog/query quarantine and observation timestamps belong to Runtime. State contains both classifications without caller-specific filtering.

Native source fields have explicit source-owned classifications. The State root decodes through the common Value representation, partitions only declared fields and rejects unclassified additions. This prevents future native runtime/configuration fields from silently entering Business.


Permission completion from microphone/camera/Photos operations and Bluetooth power changes updates the collection through an internal native notification. Foreground resume reconciles external Settings changes; there is no universal permission-change notification and no permission polling. Audio/Vision/Connectivity authorization reflection reads the same stored permission sample. Native sources with no current observation remain unknown; initializing monitoring is not a device-connection or action-readiness guarantee. Source encoding/sampling failures remain throwing reads until a later observation succeeds. Business execution continues to recheck native admission/permissions at effect time.

Permission child readers preserve the same source failure contract: cold/suspended/released ownership yields unknown, while an admitted cached-source or decoding/schema failure throws. The source and Audio/Vision/Connectivity projections do not convert an actual read error into an observed unknown permission.

VisionContainer additionally indexes and registers platform.vision.camera. This exact child projects AppleCamera resident native phase/running/facing/photo dimensions without lazy construction or hardware sampling on State reads. Camera intent, consumer arbitration and presentation priority belong to callers, not this foundation.

## Camera/audio cooperation

PlatformContainer injects AudioContainer's native owner reservation into VisionContainer's AppleCamera. One capture session supplies preview plus photo or movie output; movie microphone use is mutually exclusive with other native audio owners. Native start/terminal callbacks define recording completion. VisionContainer owns a single joined photo/video Photos-import slot. These are foundation capability constraints; listening intent, window behavior, recording duration choice and media collection remain with callers.

PlatformContainer.systemStatus() exposes a typed read of resident power/network facts for host adapters. PlatformSystemStatus belongs to Core; reading neither starts monitoring nor samples hardware. UI types and display policy are not dependencies.

Audio reports media-services reset as a native event and terminates affected PCM/playback waits with the original error. Full native stop joins work and replaces audio engines/connections; the execution owner decides whether and when to request a fresh capture. This SDK neither cancels model replies nor replays business actions. See [Audio lifecycle](Audio/README.md#原生事件错误与约束).

Audio 的语音模式复用同一采集/播放引擎并报告实际 voice-processing 能力，采集与播放分别取消；不支持时向上层返回受限能力。双工业务策略和字幕由调用方拥有，原生图与 PCM 适配见 [Audio](Audio/README.md)。

Audio 捕获事实包含实际回声消除路径。原生所有者优先受支持的系统 echo-cancelled input，回退到双 I/O 语音处理，只有验证启用后才提供全双工能力；路由失效交由原有生命周期终止/重建。SDK 不用识别文本推断回声，具体接口见 [Audio](Audio/README.md)。
