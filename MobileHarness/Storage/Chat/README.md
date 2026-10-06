# StorageChat — Conversation storage

Purpose: own conversation schemas and current/archived chat persistence. Design goals: preserve raw data, explicit bounds, atomic revision-checked writes and predictable recovery. StorageChat depends only on Storage; it performs no inference, rendering or device I/O. App assembles the store, Agents use journal/context values, and UI consumes shared record values only.

✅ ConversationHistory.swift contains record values and ConversationHistoryStore, using the core LocalDocumentStore. This directory is excluded from the Storage core target and compiles once as StorageChat. The source move changes no on-disk path, schema, version or retention behavior.

❌ Semantic memory, media files and cross-device sync are separate domains/features, not inferred from conversation persistence.

## Conversation journal

✅ ConversationHistoryStore is the Foundation-only domain store for current and archived conversations. App provides one LocalDocumentStore<ConversationArchive> and injects that owner into Assistant and the history application workflow. A nil document explicitly selects volatile storage for tests, never production fallback. The versioned payload stores original user text, exact request messages, model label/options, received text fragments, generation status/finish reason/error and optional execution error. Credentials and media are not recorded. UI computes display titles from raw input and summaryTitle; Storage contains no localized fallback.

| Bound | Policy |
| --- | --- |
| Journal document | 32 MiB encoded envelope; reject excess, no automatic eviction |
| Conversations | One current plus at most 64 archives; explicit deletion of archives |
| Turns | At most 256 per conversation; start a new conversation when full |
| Input / system / model label | 4096 / 32768 / 512 UTF-8 bytes per record |
| Received raw response | 256 KiB / 8192 fragments; reject excess preserving prior data |
| Exact request | Up to 514 messages; system content up to 32 KiB and other content up to 256 KiB per message; document bound also applies |
| Title / error | 80 characters / 4096 characters |
| Mutations | One actor-owned writer plus 16 FIFO waiters; overflow fails busy |

Each accepted fragment is atomically persisted before current Action parsing. Admission/append reserve encoded headroom for terminal error state. Disk failures preserve the previous durable revision and surface explicitly. If a terminal write fails after the producer has stopped, the in-memory record is marked interrupted with an unsaved-status error so it cannot permanently fence the next input; a later successful write persists that recovery state. Interrupted generating records loaded after restart are marked interrupted in the snapshot and excluded from context by Assistant. A subsequent successful write persists that recovery state. New conversation is one atomic archive-and-reset write; pending title failure never loses the archived conversation. An active producer blocks archival until stopped/joined.

```mermaid
flowchart TD
    Read[Current records + opaque read token] --> Caller[Assistant selects context and builds request]
    Caller --> Fence[Exact request + token validation]
    Fence --> Commit[Revision-checked atomic document write]
    Delta[Received fragment before parsing] --> Commit
    End[Completion / cancellation / failure] --> Commit
    New[Archive current and reset atomically] --> Commit
    Title[Archived title or retry error] --> Commit
    Commit --> Cache[Actor snapshot]
    Commit --> Disk[Protected local JSON]
    Disk --> Recover[Restart: generating becomes interrupted]
```

❌ Cross-process writers, cross-device sync, semantic retrieval, compressed archives and automatic retention are not implemented. Whole-document fragment writes favor diagnostic durability; no unbounded flush queue exists. Provider token budgets are independent of journal storage limits.

✅ Chat output-token budgets are optional and default to nil. Assistant/cloud requests omit max_tokens so the provider chooses its default; local Gemma 4 E2B uses remaining room in its existing 4096-token context. History omits max tokens display and preserves older explicit budgets on disk. The separate 2000-byte whole-reply cap is removed; parser, queue, timeout and per-segment bounds remain. Explicit title/warmup budgets are unchanged. ❌ Live-provider/device acceptance remains separate.

## Tool diagnostics and token usage

✅ Version-1 turns have optional toolDefinitions, toolCalls and tokenUsage fields; old files decode unchanged. Assistant persists the exact declarations and complete model-native call (provider ID, runtime UUID, name, raw argument JSON) before resolution/dispatch. App records Gateway's actual returning output, completion-only success, failure or cancellation against that UUID; late results can update archived turns. Internal presentation Tools are excluded. Received without an outcome means execution has not been confirmed; generation completion is separate.

✅ Bounds: 128 declarations / 64 KiB combined, 128 calls per turn, 512-byte provider ID, 64-byte name, 4096-byte arguments, 64 KiB result and 4096-character error. Journal still rejects over 32 MiB without eviction. A FIFO admits at most 16 waiting store operations, rejects overflow with busy, and joins each accepted atomic mutation even if the caller is cancelled. This serializes generation fragments and execution outcomes without lost updates; no inference/effect is retried.

```mermaid
flowchart LR
    Model[Native call / usage] --> Assistant[Persist before resolution]
    Assistant --> Journal[StorageChat atomic FIFO]
    Assistant --> Gateway[Existing OutputGateway]
    Gateway --> App[Actual execution outcome]
    App --> Journal
    Journal --> History[Read-only history and export]
```

❌ Old records cannot recover unrecorded calls/usage; partial native SSE calls and token IDs are not retained. Token counts are supplied by the provider/backend, never estimated from characters.

## Read and admission fencing

✅ readCurrent returns current records and an opaque token under the same bounded writer gate. begin accepts exact request messages and the token, never selects context, and rejects stale or foreign tokens with conflict. Every successful mutation invalidates the token, including archived metadata updates; failed terminal recovery also invalidates it. Reads and failed writes without state changes do not. Token values are process-local, not persisted; durable revision checks remain independent.

✅ Version-1 files and raw requests remain compatible. Admission precedes inference; Assistant reports conflicts/persistence failure without model calls or automatic retry.

❌ Cross-process transactional reads and automatic admission retry are unsupported.
