# 0082 — NexArm channel observation and host watchdogs

Date: 2026-09-30. Status: implemented.

Channel actions await observed completion while settings tests remain open-loop/preemptible. Previously notification bytes outside a pending exchange were ignored, and the controller slept for commanded duration before querying. Add a connection-owned BLE decoder and latest-pose cache, plus token-fenced observation sessions shared with serial. Notifications feed the cache independently of request continuations. Cache overflow replaces old telemetry only; byte decoding is bounded4096 bytes, serial drains16KiB. No action queue is introduced.

Command admission has a1s bound. Once admitted, the controller observes immediately, queries only after200ms silence at a maximum5Hz, and never waits for individual query replies. A2s valid-feedback silence deadline and independent nominal-duration+3s segment deadline terminate await with distinct unknown/not-arrived results. Neither refreshes the other. Arrival requires unchanged pose tolerances plus200ms/300ms encoder stability around a fixed anchor. No extra status request is needed after completion. Failure never replays a command; new explicit requests remain independent. Live settings takeover/disconnect invalidates observation tokens and cancels the old await.

✅ Tests exercise push-only, query fallback, missing feedback, total deadline, cached pre-command samples, fragmented reception and takeover. ❌ Receipt sequence/time is host-local; firmware lacks action IDs and sample timestamps, so completion remains observational. A controller timeout is not a physical stop. Device-side watchdog behavior is not changed or claimed. Generic legacy links retain their bounded exchange fallback; production BLE and USB use the observation protocol.

✅ The fixed whole-action deadline equals the sum of each segment’s nominal duration plus its3s settling/observation allowance; starting later segments cannot extend it. Dance has10 segments and a40.6s upper bound, while2s silence and nominal+3s per-segment failures still exit earlier. A single3s allowance for the entire sequence previously cut dance at leg8 before its return frames. This bounds the complete channel await as well as each segment.

## Amendment: retain trajectory ownership through nominal duration

The user reports stalls followed by apparent motor2 oscillation during celebration/dance in conversation. Code inspection found that the earlier head-mode handoff fix applied only to ready-to-native transitions. Other Cartesian and native segments could release after 200/300 ms of stable early telemetry, even while the firmware trajectory duration had not elapsed. The previous USB head investigation already demonstrated that early observed arrival could precede release of trajectory ownership; it does not prove the cause of this new physical report.

The shared tracker now requires a fresh converged sample at or after every segment's nominal duration. A caller-supplied minimum can extend but never shorten that duration. It continues observing from admission, requires the existing encoder stability, and preserves silence, segment and total deadlines. Early telemetry alone and delayed host wakeups alone cannot release the next write. The independent-new-request policy in ADR 0080 remains intentional and unchanged.

✅ Deterministic gate tests and complete push-only celebration/dance fixtures detect premature handoff. ❌ Real BLE timing, motor2 visual behavior and mechanical/firmware causes remain unverified; no torque/speed/tolerance changes or physical-stop guarantees.

Cartesian playback is superseded by [ADR0088](0088-nexarm-settings-matched-playback.md): no intermediate queries/arrival gates, shared Settings cadence, fresh final-home observation. Head segments retain this observed-arrival policy.
