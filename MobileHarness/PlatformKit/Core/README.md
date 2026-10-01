# Core — Shared Platform Contracts

Purpose: document the boundary for future contracts shared by multiple hardware domains. Design goals: add abstractions only with concrete consumers and keep business policy outside PlatformKit.

✅ Current adapters perform authorization through their public platform APIs. The unused DeviceCapability/AuthorizationStatus/PermissionProvider declarations have been removed; there is no compiled Core implementation today.

❌ A shared permission service remains unimplemented. Add a contract here only when multiple adapters and real callers need it, with explicit authorization behavior and tests. This directory is documentation only and owns no queue or lifecycle.
