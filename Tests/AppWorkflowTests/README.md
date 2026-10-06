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


✅ Model resources preferences persist forced-system speech before apply; invalid edits do not change saved policy. Restore applies the default once and cache avoids redundant effects.


✅ Single handler speech failure presentation preserves the underlying description rather than replacing it with 执行失败.


✅ Resource policy tests reject missing Nemotron and MOSS before persistence, preserve independent toggles, keep recognition enabled after Silero removal and disable it after Nemotron removal, normalize stale preferences before apply, preserve endpoint/cellular policy and coalesce concurrent migration/apply.

✅ Restoration tests verify legacy cellular restriction migration is persisted before a new download consumes it.

✅ Workflow fixtures import built-in application identities from Agents rather than AgentCore. Production feature workflows keep their own source-selection policy without depending on concrete Agents.

✅ Presentation regression tests use opaque provider codes/details while preserving motor failure display and unknown-code fallback. ❌ These tests perform no device effects.

✅ AudioDetectionWorkflowTests exercises automatic completion, one-operation admission, joined cleanup before restart, late-callback fencing and permission failure/retry using an injected endpoint without a microphone or models. ❌ It does not validate physical capture.

✅ ADR0131 regressions cover independent output failure projection, stale-revision rejection, bounded background issues and eviction counts without creating scheduler Action records. ❌ Physical UI acceptance remains pending.

✅ History workflow fixtures use exact requests with read tokens; archive/title/delete operation behavior remains unchanged. ❌ Agent-based history coordination remains planned.

✅ History fixtures explicitly inject refresh effects; failed preparation cannot invoke refresh, and archive/title cancellation contracts remain tested. ❌ Native page interaction remains unverified.

✅ ModelResourceInteractionWorkflowTests migrates resource admission/cancel/source/rollback regressions from UITests and adds cancelled-page-caller acceptance. Fixtures use the owning ModelResourcesOperating contract and no network/model weights. ❌ Native UI interaction remains separate.

✅ History fixtures now inject explicit deleteArchive operations; production legacy workflow cannot directly delete the journal. Archive/title regressions remain unchanged. ❌ Native confirmation and conversational deletion acceptance remain pending.
