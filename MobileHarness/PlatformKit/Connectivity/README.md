# Connectivity — External Device Communication

Purpose: group communication with external hardware by capability rather than device category. Design goals: separate transport from Agent decisions and future robot-specific command semantics.

- ✅ ExternalDeviceTransport defines actor-isolated connect, send, emergencyStop and disconnect operations; its API is unchanged.
- ❌ Concrete BLE/network transports, command validation, bounded transport queues, hardware watchdogs and physical stop acknowledgements are not implemented.

The protocol alone provides no safety guarantee. Future adapters must document bounded admission, overflow, cancellation and completion; robot hardware must enforce its own safety independently of app execution. No placeholder transport implementation is provided.
