# ADR0143 — Storage and Consumer Policy Boundaries

Date: 2026-10-06. Status: implemented.

## Context

Storage had independent imports but selected Assistant context, supplied UI title defaults and named/localized synthesis failures. These responsibilities obstruct the staged [Agent-driven app](../../MobileHarness/README.md) design.

## Decision

Assistant builds its exact request from ten completed rounds. StorageChat returns current records and an opaque process-local read token; begin requires that token and preserves the supplied request. Every successful mutation and failed-terminal in-memory recovery invalidates it. Stale/foreign tokens fail with conflict before inference, without retry. Durable revisions, 16 FIFO waiters and version-1 schema remain unchanged.

UI selects display titles and default wording. SpeechSynthesis owns timedOut/invalidOutput; StorageAudio retains PCM/lease/cache validity and transparently conveys caller failures. The App playback adapter supplies localized wording after cleanup and retains the underlying error.

## Consequences

✅ No new target, Agent, queue or persisted schema. Existing context, title and playback behavior remains, with explicit read/admission fencing and producer-owned errors.

❌ History workflow Agent migration, shared UI intent and model Tool-result continuation remain future stages. Physical behavior is not established by source or synthetic validation.

## Validation

✅ Final targeted tests (32), static/format checks and unsigned iOS device build passed. ❌ The full check retained one audio detection timeout (isolated rerun passed); simulator builds remain blocked by external CoreAIShared. See [dated evidence](../validation/Validation-History.md#2026-10-06--agent-driven-app-storage-boundary-stage).
