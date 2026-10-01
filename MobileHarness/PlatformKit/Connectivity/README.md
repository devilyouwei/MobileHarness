# Connectivity — External Device Communication

Purpose: implement bounded transport and protocol capabilities for external hardware. Design goals: explicit admission, observable connection state, structured diagnostics and no action/presentation policy.

✅ [NexArm](NexArm/README.md) implements USB/BLE links, framing, native motor register encoding, hardware position limits, timestamped feedback and connection-health tracking. Device SDKs may know vendor commands and limits; they must not know application gestures, home/reset behavior, motion recipes, localized UI text or preferred discovery ordering.

✅ Connections use the concrete NexArm link capabilities. The unused generic transport/emergency-stop placeholder has been removed; no implemented emergency-stop capability is claimed. App supplies persisted selection, foreground/reconnection lifetime and UI mappings. Actions owns all action behavior and wrappers.

```mermaid
flowchart LR
    Actions[Action behavior] --> Protocol[Device protocol and native commands]
    Protocol --> Link[Bounded USB / BLE link]
    Link --> Device[Hardware]
    Device --> Feedback[Structured telemetry and connection facts]
    Feedback --> Consumer[Actions / App adapters]
```

❌ General network transports, device-side watchdog validation and independently confirmed physical emergency stop remain unimplemented. iOS process lifetime is not a hardware safety mechanism.
