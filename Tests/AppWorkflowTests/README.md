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

✅ AppWorkflows now owns generic execution-to-display mapping; tests inject Agent observations and inspect UI-owned display values. Tests cover verb-independent cancellation/completion wording, exact case-sensitive unknown Channel names and display aggregation of concurrent work from different tasks. No production Action-name map is duplicated by the tests. ❌ Native visual/device acceptance remains separate.

✅ App-owned execution-to-display mapping is tested here, including partial failures and per-motor details; UI tests no longer construct Agent result payloads.

✅ ADR0098: Fixtures explicitly import ActionRuntime/ToolRuntime where execution contracts are used. Behavior coverage is validated separately from assembly, and history title operations are injected without changing real journal/title regression behavior.

✅ SettingsTransactionTests validates provider preparation before mutation and failed application rollback before releasing the settings barrier, without real Keychain/provider calls.

✅ Independent-output regressions prove rejected tracking calls are reported without terminating subsequent consumption; cancellation propagates instead of becoming an ordinary rejection.

## Local model resources — current contract

✅ ModelResourcesWorkflowTests verifies source persistence and download use of saved endpoint/cellular policy; invalid edits leave prior durable configuration intact.

❌ Full device/background acceptance and remaining enhancement items are tracked in [Management](../../MobileHarness/ModelKit/Management/README.md). Earlier planned sections describe the full proposal; this current contract supersedes claims that downloads are entirely unimplemented.
