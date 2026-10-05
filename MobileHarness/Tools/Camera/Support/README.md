# Camera Tool Support

Purpose: bind explicit entries to the host camera capability. Design goals: required typed injection, no discovery and no owned device/session state.

✅ CameraToolModule defines three completion-only handlers. CameraControlCapability exposes setEnabled and flip with opaque ToolInvocation correlation. CameraControlError reports foreground, busy, disabled, permission and availability failures. No queue or platform dependency.

```mermaid
flowchart LR
    Catalog[ToolModules] --> Module[CameraToolModule]
    Module --> Definitions[Generated definitions]
    Definitions --> Entries[CameraTools entries]
    Entries --> Host[Required CameraControlCapability]
```

❌ No fallback camera, permission bypass, native Tool transport or device readiness claim.

✅ ADR0132: Domain validation/availability errors provide bounded ToolRuntime producer codes; generic execution and home observation preserve them without importing platform errors. ❌ Physical acceptance remains pending.
