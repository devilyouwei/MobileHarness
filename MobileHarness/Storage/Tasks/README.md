# Task Repository

## Responsibility and implementation

✅ TaskRepository.swift defines async creation/completion and an opaque namespace. MemoryTaskRepository stores bounded ephemeral business records (8192 default, explicit capacity constructor), uses independent local primary keys and never claims restart durability. SQLiteTaskRepository.swift owns tasks schema, committed AUTOINCREMENT allocation and interruption/completion SQL; it compiles only in StorageSQLite.

## Direct relationships

StorageTasks depends only on Storage. Chat/Agents consume the protocol; App constructs/injects a backend family. No model decisions, Skill transitions, native effects or inferred execution success belong here.

## Lifecycle and failure contracts

Running creation commits before activation; terminal update never reopens a completed record. Parent references validate within the same backend. Binding failure is explicitly finished by the Agent, not silently removed. Source/compression projections belong to Chat and its atomic checkpoint contract.

## Outstanding work

❌ Persistent Task queries/UI and remote backends are separate work.

[Storage](../README.md)


✅ Task creation/terminal updates use a private GRDB record. Creation commits running and returns the key before activation. Runtime changes remain in memory, terminal transitions flush status/summary/failure. No Task JSON snapshots or implicit ORM writes.
