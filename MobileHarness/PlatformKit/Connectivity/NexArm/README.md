# NexArm connectivity and protocol SDK

Purpose: provide reusable NexArm USB/BLE connection, framing, native motor commands and feedback. Design goals: no business gesture catalog, no Action or Channel dependency, bounded transport state and explicit failures.

✅ `NexArmProtocol.swift` owns packets, decoding, link capabilities, timestamped telemetry and connection feedback health. Packet properties describe single/synchronous position writes and motor targets without head/gesture terminology. `NexArmBluetooth.swift` and `NexArmSerial.swift` implement transports and observation sessions. Admission, disconnect and manual takeover fence old sessions; failed motion commands are never automatically replayed.

✅ `NexArmMotorCommands.swift` encodes native single-motor position writes and simultaneous addressed writes. Speed1…1400 and acceleration1…254 use native register units. Hardware position limits belong to the encoder. The SDK exposes no reset/home wrapper or joystick planner: these are Action-side behavior.

✅ This target has zero project dependencies and owns its device values. Actions consumes its link protocols through injected connections; PlatformKit never imports Actions, enumerates gestures, supplies localized action names or decides an Action result. The boundary check rejects reverse imports and reintroduced action policy types.

```mermaid
flowchart LR
    Settings[App Settings adapter] --> Actions[Actions/NexArm: presets and execution policy]
    Channel[Channel via App binding] --> Actions
    Actions --> Protocol[PlatformKit: link protocols / motor encoder]
    Protocol --> Transport[USB / BLE transport]
    Transport --> Device[Arm firmware]
    Device --> Feedback[Timestamped passive feedback]
    Feedback --> Actions
```

Manual jog shaping, reset wrappers, arrival/stability thresholds, gesture geometry, own-motor preparation/reset, child-error aggregation and connection indication belong to [Actions/NexArm](../../../Actions/NexArm/README.md), specifically its [Support](../../../Actions/NexArm/Support/README.md) implementation.

Developer rules: add protocol operations here only when they are reusable device capabilities. Put nod/dance/celebration, localized names, beats and business completion rules in Actions. Never make a transport enumerate all Actions or choose which gesture follows connection. Stationary read-only queries remain available; production Actions observe unsolicited feedback without polling fallback. Live and observed position writes share the same native per-motor limits; the former full-encoder-range fallback is removed. Packet admission validates addressing and bounds; it is not physical obstacle detection.

❌ No autonomous safety controller, physical emergency-stop proof, firmware calibration, arbitrary register configuration or guaranteed background execution. BLE/USB transport checks do not establish physical clearance or gesture quality.

✅ BLE failures carry typed step/cause/native domain/code data. Device snapshots contain transport facts; App owns name-priority ordering, placeholder filtering, localized text and recovery advice. Protocol names are bounded and normalized without localized placeholder interpretation.

✅ BLE reply timeouts retain expected command/payload length and total received notification bytes before pending state is cleared. Zero notifications and unmatched data can be distinguished. The SDK never replays a request; read-only response timeouts preserve the link with quarantined exchanges, while write/native transport failures disconnect. App owns localized labels.

✅ Read-only response timeout keeps the radio and notifications connected but quarantines exchanges until reconnect; feedback/control health stays false. This preserves connection truth without allowing a late response to satisfy a new request. Write/native transport failures still disconnect. No motion retry is introduced.

## Shared BLE pacing and diagnostics — ADR0123

✅ One connection-wide admission budget spaces actual writes by at least 30 ms (about 33 packets/s, burst capacity one). Observed writes, live writes and acknowledged requests share it; CoreBluetooth writeWithoutResponse readiness and packet-size checks still apply. This is a conservative initial transport ceiling, not a measured firmware limit. Reconnection resets the budget; observation/manual takeover does not refill it. Idle time never accumulates credits.

✅ Streaming retains no packet queue: `false` means not sent, so the owner retains/recomputes its latest intent. A finite request reserves the existing capacity-one request slot before a cancellable pacing wait; a concurrent request fails busy. Takeover/disconnect cancels that unsent request task. Only a request actually written can leave an outstanding ATT acknowledgment. No command is silently dropped or automatically replayed. The existing five-second request deadline includes pacing; feedback silence remains two seconds.

✅ `status().traffic` exposes fixed-size, connection-local saturating counters for admitted packets/bytes, pacing and system deferrals, readiness callbacks, raw notification bytes and valid feedback samples, plus current/maximum notification and feedback gaps. OSLog emits a summary every approximately five seconds and on feedback-health transitions. Raw notification traffic is counted before decoding, so unrelated/malformed data is distinct from valid pose receipts. No media or packet payload is retained in diagnostics.

```mermaid
flowchart LR
    Live[Live owner: latest intent] --> Budget[Shared 30 ms write budget]
    Observed[Observed finite action: retry unsent admission] --> Budget
    Request[Single reserved request: cancellable wait] --> Budget
    Budget --> Flow[CoreBluetooth readiness / size validation]
    Flow --> Wire[Actual native write]
    Wire --> Advance[Advance shared deadline]
    RX[Notifications] --> Facts[Raw bytes / valid feedback / gaps]
```

❌ Physical BLE rate/MTU/firmware endurance calibration and device-side queue instrumentation remain pending. Native multi-motor packing is available but streaming does not assume a negotiated MTU can fit a combined packet. No claim of solved wireless interference or firmware starvation.

This transport change does not add automatic reconnect after feedback loss while BLE remains connected. App still requires explicit control verification/reconnect for that case; physical disconnection retains its existing bounded recovery policy.
