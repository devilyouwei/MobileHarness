# Platform Core — Native lifetime tools and system facts

## Ownership and interfaces

Core uses system libraries only. It does not know Agents, Signals, Actions, Gateway, UI presentation or application policy. NativeBackgroundAllowance owns a single OS background allowance/deadline and ends a replaced allowance idempotently; it grants no long-lived background execution guarantee. NativeInputBroadcast distributes SDK values without starting capture or choosing a business response.

NativeSystemState.swift defines the exhaustive PlatformStateSource enum and PlatformStateReading JSON read contract. PlatformContainer implements that port; this directory owns system time, power, thermal, locale and accessibility queries. Audio, Vision and Connectivity own their respective native facts; the root composes those public SDK values without business interpretation.

## Resident State collection and native sampling

The collection seeds time at start, updates it on an owned one-second timer and significant time/zone events, and reseeds it on foreground resume. Each native time sample captures one injected Date and one current TimeZone. Gregorian formatting with en_US_POSIX produces localDateTime to seconds with an offset, an English weekday and the zone identifier. All fields derive from that same pair. State reads return the stored sample without consulting the clock; clock/zone replacement and update events are testable. Nonfinite input rejects explicitly. Wall-clock observations do not replace monotonic deadlines used by native execution.

Power contains batteryLevel (0…1 or null), batteryState and lowPowerMode. Root start explicitly enables iOS battery monitoring; stop restores the prior setting. Unknown readings do not become zero percent. Thermal contains the OS nominal/fair/serious/critical level, with unknown for unrecognized future values. Locale contains identifier, preferredLanguage and region; it is not geolocation or an instruction overriding user preference. Accessibility contains voiceOver, reduceMotion, closedCaptions and monoAudio. Unsupported host fields remain null. Reads do not request permissions, activate audio or operate hardware.

NativeSystemState.encode validates bounded JSON output of at most 8 KiB. These JSON objects contain native facts only; Agents owns source names and the model envelope. Unavailable root admission rejects collection. NativeStateCollection holds one bounded Result<Data, Error> per synchronous source, preserving failures rather than fabricating values. There is no cross-module global mirror, native polling, Gateway publication or implicit capability discovery.

## Broadcast and cancellation

NativeInputBroadcast permits at most 16 subscriptions. latest retains one value per subscriber with replacement counters; ordered retains 64 values and terminates only the overflowing subscriber with an explicit error. finish closes current subscriptions, without executing native stop or replaying data. Capture generations and native device cleanup remain owned by Audio/Vision/Connectivity.

[PlatformKit](../README.md) · [State read path](../../Agents/Support/Context/README.md#container-context-read-path)

PlatformStateSource also declares the complete Business/Runtime field sets for each native JSON schema as producer-owned data. The root rejects keys without a declared classification; source changes must update the schema explicitly. This is independent of caller visibility selection and retains all native fields.


NativeStateCollection registers notifications before baseline sampling. MainActor serializes both the baseline and source refresh, so a queued notification refreshes from current native truth after the baseline; an old baseline cannot overwrite a newer committed event. Bursts merge into one finite source set and one worker. The network owner independently retains its generation-fenced latest event. Permission changes are reconciled after native permission operations, Bluetooth power events and foreground resume. Snapshot reads perform no sampling or restoration. Invalidation retires the generation before removing observers/cancelling the worker and timer; the root joins the worker, and late old-generation callbacks cannot modify a resumed collection. Deinitialization also removes observers and invalidates the clock.

PlatformSystemStatus将既有power/network缓存解码为类型化电量、充电、低电量模式和网络路径类型，由根systemStatus()提供只读能力。缺失电量保留nil，越界值明确失败；路径未满足不声称连接或信号强度。该投影不增加观察器、计时器或原生采样。
