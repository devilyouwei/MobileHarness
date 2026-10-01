# Connectivity — External Device Communication

Purpose: group communication with external hardware by capability rather than device category. Design goals: separate transport from Agent decisions and future robot-specific command semantics.

- ✅ ExternalDeviceTransport defines actor-isolated connect, send, emergencyStop and disconnect operations; its API is unchanged.
- ✅ `NexArmJointCommand` maps logical `base` / `pitch` to six raw positions and builds the position-write frame (command 97, little-endian, checksum). Provisional home is raw 2048. `base` changes `shoulder_pan`; `pitch` changes `wrist_flex`.
- ✅ `NexArmController` sends that frame on an injected transport. `home()` throws `provisionalHome` and does not move hardware.
- ❌ Concrete Wi-Fi/BLE/network transports, bounded transport queues, hardware watchdogs and physical stop acknowledgements are not implemented. The intended NexArm endpoint is `192.168.4.1:8080`. The camera session does not connect.

The protocol alone provides no safety guarantee. Future adapters must document bounded admission, overflow, cancellation and completion; robot hardware must enforce its own safety independently of app execution. No placeholder transport implementation is provided.
