# ADR 0057: Local settings persistence and cache synchronization

Status: accepted, 2026-09-28.

Storage owns caching, persistence and their synchronization, extending ADR 0056 beyond transient PCM. The first durable consumer is App user settings. Use a generic Foundation-only actor with a bounded JSON envelope, explicit refresh/invalidation, revision comparison and atomic write-through persistence. Writes do not queue in the background; stale writers fail. A process lock coordinates local instances, not external processes.

App owns the sandbox path and payload schema. Nonsecret fields and credential references live in Application Support/MobileHarness/Settings/settings.json; credentials remain in device-only Keychain. Exclude the directory from backup. Optional repository-local data uses ignored .local/. Production configuration is not bundled or hard-coded.

Migration reads the existing Keychain configuration, stages a new credential, commits and verifies the document, then deletes the legacy record. A failed document commit retains the old state. Corruption or missing credentials is an error, not permission to reset settings. Keychain and file updates are not jointly atomic; interrupted post-commit cleanup can leave an orphan credential. Automatic orphan cleanup is deferred.

This stage synchronizes memory with local disk only. Cross-device synchronization, cross-process coordination, general disk-cache eviction and persistent media require separate consumers and designs. Existing bounded PCM lifetime semantics are unchanged.
