# Connectivity — External Device Communication

Purpose: group communication with external hardware by capability rather than device category. Design goals: separate transport from Agent decisions and future robot-specific command semantics.

- ✅ ExternalDeviceTransport defines actor-isolated connect, send, emergencyStop and disconnect operations; its API is unchanged.
- ✅ `NexArmJointCommand` maps logical `base` / `pitch` onto the five arm axes and builds the same motors-1–5 packet used by production motion. The rest pose is `[2048, 2087, 1198, 1238, 2048]`. `base` changes `shoulder_pan`; `pitch` changes `wrist_flex`. The suction-cup gripper is not in the packet. The camera session does not send it.

The protocol alone provides no safety guarantee. Future adapters must document bounded admission, overflow, cancellation and completion; robot hardware must enforce its own safety independently of app execution. No placeholder transport implementation is provided.

✅ [NexArm](NexArm/README.md) now implements a bounded macOS USB diagnostic transport, protocol parser and bounded motion controller. It does not claim the generic emergency-stop contract. ❌ BLE/TCP and device-side watchdog validation remain pending.

✅ NexArm now includes iOS/macOS CoreBluetooth discovery, explicitly selected connection, FFE1 writes, FFE2 notifications and bounded request matching. App owns persisted selection and foreground policy; PlatformKit owns no Agent, Gateway or UI types. ❌ General external-device watchdog/stop semantics remain unverified.
