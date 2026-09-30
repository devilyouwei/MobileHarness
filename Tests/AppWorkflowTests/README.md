# App Workflow Tests

Purpose: test cross-module history operations using the real journal and a controlled ChatCapability. Design goals: observe durable state at explicit start/completion boundaries without sleeps or real providers.

✅ Archive/reset commits before title generation; overlapping archive/delete requests do not alter active work. Cancelling title generation retains raw history and a retryable title error. Retry stores the final title. Failed loading never creates a fallback memory store.

❌ Keychain/provider migration and physical-device diagnostic playback acceptance.

## Storage domain organization

✅ History workflow fixtures use StorageChat records/stores plus Storage document primitives. No behavior change or new queue is introduced.

❌ Image/video/semantic-memory stores remain planned; this migration adds no storage behavior.

✅ ActionActivityTests covers channel grouping and queue counts,3s terminal hiding without history loss, failure dismissal/supersession, stale revisions, state/activity completion wording, honest cancellation-pending wording and injected snapshot consumption independent of page lifetime. ❌ Real-device visual/accessibility acceptance remains separate.

✅ Projection regression verifies all scheduled Actions remain visible, including UI/perception-originated fixtures; immediate Tools never create scheduler records.

## Action and Tool presentation boundary

✅ Presentation tests require every scheduled Action regardless of module/source, and verify arbitrary thrown descriptions display without a per-Action error mapping. ❌ Fixtures do not assert physical motion.
