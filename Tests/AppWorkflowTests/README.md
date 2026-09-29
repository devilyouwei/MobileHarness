# App Workflow Tests

Purpose: test cross-module history operations using the real journal and a controlled ChatCapability. Design goals: observe durable state at explicit start/completion boundaries without sleeps or real providers.

✅ Archive/reset commits before title generation; overlapping archive/delete requests do not alter active work. Cancelling title generation retains raw history and a retryable title error. Retry stores the final title. Failed loading never creates a fallback memory store.

❌ Keychain/provider migration and physical-device diagnostic playback acceptance.

## Storage domain organization

✅ History workflow fixtures use StorageChat records/stores plus Storage document primitives. No behavior change or new queue is introduced.

❌ Image/video/semantic-memory stores remain planned; this migration adds no storage behavior.
