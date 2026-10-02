# Storage — Shared Local Storage

Purpose: provide one project-wide home for transient and durable data used by multiple domains. Storage concerns ownership, lifetime, capacity and retrieval. Agents decide what is worth remembering; ModelKit produces model results using shared media values; PlatformKit operates devices. Storage does not perform inference, choose Actions or control hardware.

## Design goals

- Offer a common identity and ownership model for audio, images, attachments, documents and memory records. Each item has an opaque ID, namespace, originating scope and an explicit lifetime policy.
- Distinguish **memory** (process-local and bounded), **cache** (reclaimable, optionally disk-backed) and **persistent** (retained until explicit deletion or a documented retention rule). A disk cache does not promise durable memory.
- Make byte/item limits, expiry, rejection, deletion, cancellation and shutdown explicit. Active readers need leases so expiry cannot remove data mid-consumption; no accepted device Action may disappear silently.
- Keep storage values independent of ModelKit media types and SwiftUI. Domain adapters convert audio frames, images or structured memories at the boundary. App assembles and injects one service where sharing is required.
- Persist large media as bounded files with metadata/indexes rather than forcing all bytes into a database row. A future database may support durable metadata and memory queries; no engine or third-party library is selected yet.

## Upstream and downstream

The base `Storage` target depends only on Foundation. Its direct production consumers are App/AppWorkflows (document assembly/settings), StorageChat (conversation persistence) and StorageAudio (bounded PCM primitives). Agents import StorageChat and StorageAudio. Scheduled Speech Actions consume audio through AppSpeechPlayback.SpeechPlayback; Actions does not depend on StorageAudio. UI imports StorageChat conversation record values only; its pages receive state/operation interfaces rather than a store. These arrows show runtime use, not reverse imports into Storage.

```mermaid
flowchart LR
    App[App settings and composition] --> Documents[LocalDocumentStore]
    App -.->|Inject same history service| Assistant[Assistant]
    App -.->|Inject history workflow| Views[UI/Settings]
    Views -->|User operations| Workflow[App settings / history workflows]
    Assistant -->|Context and raw turn persistence| History[ConversationHistoryStore]
    Workflow -->|Inspect, archive, title and delete| History
    History --> Documents
    Documents --> Disk[Bounded protected JSON and cached snapshot]
    Synth[SpeechSynthesisAgent] --> Audio[StorageAudio PCM adapter]
    Playback[AppSpeechPlayback: Action-bound endpoint] -->|Checkout and release| Audio
    Audio --> Memory[MemoryLeaseStore and BoundedMemoryStream]
```

Generic persistent media files and reclaimable disk caches remain planned; the current durable implementation stores settings and conversation records. ModelKit and PlatformKit do not depend on Storage; both consume independent Types values.

## Local cache and persistence synchronization

`LocalDocumentStore<Value>` is a Foundation-only actor providing one bounded JSON document and its read-through, write-through memory cache. The default encoded envelope limit is 64 KiB; oversized reads/writes fail explicitly. One cached snapshot is retained per instance, with no background write queue. App injects a trusted sandbox file URL; the consuming domain owns the payload schema.

- `load()` reuses the cache; `refresh()` reads disk and replaces the cache only on success; `invalidate()` releases the cached value.
- `save(_:expecting:)` rereads the durable revision, rejects stale writers, atomically replaces the file and then updates the cache. A nil expected revision requires an absent file. Failed writes leave the cache unchanged.
- A process-wide lock protects revision comparison and replacement across instances, including different payload types. This is local synchronization, not cross-process locking or cross-device replication. App assembles one owner per settings file. External edits are noticed by refresh or the next save; no filesystem watcher is installed.
- Envelope version 1 is independent of the consumer payload version. Invalid JSON, unsupported envelopes and nonregular files fail explicitly; corrupt data is never silently reset. iOS writes use complete file protection. App controls backup and credential policies.
- App settings and StorageChat are durable consumers. PCM remains transient with explicit reply/session-owned retention and bounded capacity; it does not expire merely while waiting for playback.

```mermaid
sequenceDiagram
    participant App
    participant Cache as Storage actor/cache
    participant Disk as Local document
    App->>Cache: load / refresh
    Cache->>Disk: bounded read when needed
    Disk-->>Cache: value + revision
    App->>Cache: save(value, expected revision)
    Cache->>Disk: locked compare + atomic replace
    Disk-->>Cache: success or conflict/error
    Cache-->>App: update cache only after success
```

## Primitive ownership and lifetime

✅ BoundedMemoryStream and MemoryLeaseStore are actor-isolated process-local primitives with explicit overflow failure, scoped owners, single-reader/checkout behavior, cancellation and optional expiry. StorageAudio adapts these primitives to reply/session-owned PCM. App supplies the shared instance to synthesis and playback.

MemoryLeaseStore accepts nil queueTTL/readyTTL for owner-managed values without arming expiry tasks. BoundedMemoryStream accepts a nil read timeout, leaving completion to producer finish/failure or cancellation. StorageAudio uses both owner-managed policies; bounded error tombstones expire separately.

❌ Global cross-namespace byte budgets, reclaimable disk caches, persistent media, semantic memory and cross-device/cross-process synchronization are not implemented. Each instance supplies its own item/byte bound. Model weights belong to Resources.

## Directory and target ownership

```text
Storage/                         # Storage target: reusable storage mechanisms only
├── BoundedMemoryStream.swift     # Bounded transient data stream
├── MemoryLeaseStore.swift        # Generic in-memory handles/leases, not semantic memory
├── LocalDocumentStore.swift      # Persistent JSON, cached snapshot and revision synchronization
├── README.md
├── Audio/                       # StorageAudio: audio lifetime and PCM contracts
│   ├── SpeechAudio.swift
│   ├── SpeechAudioStore.swift
│   └── README.md
└── Chat/                        # StorageChat: conversation records and journal
    ├── ConversationHistory.swift
    └── README.md
```

The outer layer owns reusable cache, persistence and local synchronization mechanisms. Domain directories own schemas, domain limits, retention and domain-specific APIs. Chat and Audio depend on core; core never imports a domain. StorageChat depends only on Storage.

| Domain | Status and responsibility |
| --- | --- |
| Audio/ | ✅ Process-local single-use PCM; persistent audio remains pending |
| Chat/ | ✅ Raw conversation records, current/archived history, context extraction and durable journal |
| Image/ | ❌ Planned only: image metadata, file/cache handles and retention |
| Video/ | ❌ Planned only: video files, finalization and retention |
| Memory/ | ❌ Planned only: semantic memory records, provenance, retrieval and forgetting; not the core MemoryLeaseStore |

Domain targets depend on core mechanisms, never the reverse. App owns settings payload/credential policy and uses the generic document store. StorageAudio consumes Types values and opaque source identity; StorageChat consumes Storage alone.

See [Chat](Chat/README.md) for the journal contract and [Audio](Audio/README.md) for PCM contracts.
