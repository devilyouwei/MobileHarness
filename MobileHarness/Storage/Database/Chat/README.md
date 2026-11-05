# Chat rounds, requests and checkpoints

StorageChat depends on StorageCore and StorageTasks. ConversationRecords.swift owns values;
ConversationHistory.swift owns the in-memory workflow; ConversationRecordStore.swift adapts it to
ChatRepository. SQLiteChatRepository compiles in StorageSQLite and implements the contract there.
Agents own prompt selection, Task semantics, execution, cancellation and model configuration.

## Physical records and projections

messages stores one original business round, with input/output and optional structured metadata.
Foreground-task boundaries split a round into segments with the same original input identity. Logical
input counts remain distinct-input counts. A round belongs to assistant_conversations XOR writer_tasks.
Writer does not create an Assistant conversation or participate in foreground-task compression.

Each actual invocation lives in model_request_log, with a UUID request identity, phase/attempt/provenance,
request/context JSON, full actual response, native call/result pairs, timing, usage and errors. Agent-submitted request parameters and received ChatEvents are separate from local tool outcomes;
no raw HTTP/SSE is claimed. Dynamic system/State
is preserved in request logs, never ordinary user text. The Messages adapter strips request system
arrays from round metadata. Full snapshots intentionally duplicate context; no chunk/dedup codec exists.
Auxiliary conversation-title inference uses a log with a conversation owner and no fabricated round.

History APIs project input/observation/response values from rounds and logs. message_N identifies a
round; request_N addresses a request detail. Raw enumeration paginates rounds with an explicit next
cursor, preserving all nested logs. Request previews read small columns and producer/tool metadata;
complete payloads load on detail/export. Request ordinals count the whole owning history, not a page.

## Summaries and context

assistant_tasks contains the summary, first-source anchor and source/summary revisions. Saving changed
request evidence invalidates an older summary. Only a terminal, nonempty summary/failure with matching
coverage folds sources; missing, stale or failed summaries leave originals visible. Expanded/raw reads
retain the complete original rounds and request pairings. Writer never uses this folding mechanism.
The existing bounded recent context window remains independent of complete durable history.

## Lifecycle and failures

Complete user admission, observations and request completion checkpoint independently; source token
deltas do not cause SQL writes. Failure/cancellation stores received text and actual terminal evidence.
Model completion differs from Action/delegation completion. Dirty checkpoints remain retryable after
failed publication. History has sixteen waiting writers; its adapter also serializes asynchronous
checkpoints/rotation. Publication caches change only after SQL success. Paired Chat/Tasks must share
storageScope. Agent ownership checks reject foreign history.

Assistant current/archived rotation is atomic; late updates to existing archived records remain valid,
new archived inserts fail. Writer current history is selected from its accepted task, not a globally
rotated Writer conversation. Startup interrupts generating records without rerunning work. Root lifecycle
and database closure are shared with all repository ports. Memory-only mode is explicit and ephemeral.

A reserved request may acquire a foreground task after startTask executes. SQLite resolves the request
UUID before selecting a segment and atomically moves only a previously unassigned request to that task.
The request_N address, input and evidence stay stable; prior requests remain in their original segment.
A sole request can retain its existing round. Cross-owner/input moves and established-task rebinding
are conflicts. Pending-input reads consider every segment of the logical input, preventing an empty
source segment from appearing unanswered after transfer.
