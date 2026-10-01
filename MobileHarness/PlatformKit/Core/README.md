# Core — Shared Platform Contracts

Purpose: hold small contracts shared across hardware capability domains. Design goals: keep permission vocabulary independent of concrete devices, models and Agent policy; avoid duplicating authorization types in Audio and Vision.

- ✅ DeviceCapability, AuthorizationStatus and PermissionProvider retain their existing public API.
- ❌ A unified concrete PermissionProvider is not implemented; existing device adapters perform their own permission checks.

This is the shared-contract exception to capability-domain directories. It owns no device instance, queue or lifecycle. Domain-specific implementation belongs in its owning domain, not Core.
