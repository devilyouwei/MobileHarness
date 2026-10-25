# Platform Core — Native lifetime tools and system facts

## Ownership and interfaces

Core uses system libraries only. It does not know Agents, Signals, Actions, Gateway, UI presentation or application policy. NativeBackgroundAllowance owns a single OS background allowance/deadline and ends a replaced allowance idempotently; it grants no long-lived background execution guarantee. NativeInputBroadcast distributes SDK values without starting capture or choosing a business response.

NativeSystemState.swift defines the exhaustive PlatformStateSource enum and PlatformStateReading JSON read contract. PlatformContainer implements that port; this directory owns system time, power, thermal, locale and accessibility queries. Audio, Vision and Connectivity own their respective native facts; the root composes those public SDK values without business interpretation.

## Time and synchronous facts

A time read captures one injected Date and one current TimeZone. Gregorian formatting with en_US_POSIX produces localDateTime to seconds with an offset, an English weekday and the zone identifier. All fields derive from that same pair. No clock timer, Task or cached time is maintained; clock/zone replacement is testable. Nonfinite input rejects explicitly. Wall-clock observations do not replace monotonic deadlines used by native execution.

Power contains batteryLevel (0…1 or null), batteryState and lowPowerMode. Root start explicitly enables iOS battery monitoring; stop restores the prior setting. Unknown readings do not become zero percent. Thermal contains the OS nominal/fair/serious/critical level, with unknown for unrecognized future values. Locale contains identifier, preferredLanguage and region; it is not geolocation or an instruction overriding user preference. Accessibility contains voiceOver, reduceMotion, closedCaptions and monoAudio. Unsupported host fields remain null. Reads do not request permissions, activate audio or operate hardware.

NativeSystemState.encode validates bounded JSON output of at most 8 KiB. These JSON objects contain native facts only; Agents owns source names and the model envelope. Unavailable root admission rejects collection. There is no global fact mirror, periodic sampler, Gateway publication or implicit capability discovery.

## Broadcast and cancellation

NativeInputBroadcast permits at most 16 subscriptions. latest retains one value per subscriber with replacement counters; ordered retains 64 values and terminates only the overflowing subscriber with an explicit error. finish closes current subscriptions, without executing native stop or replaying data. Capture generations and native device cleanup remain owned by Audio/Vision/Connectivity.

[PlatformKit](../README.md) · [State read path](../../Agents/Support/Context/README.md#container-context-read-path)
