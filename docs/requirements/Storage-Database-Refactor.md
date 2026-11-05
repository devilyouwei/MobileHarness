# Storage database and Writer workspace refactor

## Approved requirements

Use one shared SQLite database and exactly ten domain tables: assistant_conversations, messages,
assistant_tasks, writer_tasks, agent_delegations, model_request_log, workspace_files, media_files,
message_media and devices. Development databases may be rebuilt; no old-schema importer or dual writes.
Messages own complete business rounds; model_request_log owns individual requests and complete protocol
JSON, dynamic system/State, native calls/results, timing, usage and failures. Assistant task summaries
replace only covered terminal task content in projections; originals remain readable. Writer history
belongs directly to writer_tasks, independent of Assistant conversation deletion. Delegations record
individual execution identities, cancellation, outcomes and durable report receipts.

Writer workspace is a current directory at writer/task_N, with no historical versions. Filesystem
bytes are authoritative; SQLite indexes metadata only. Atomic file replacement and temporary reader
snapshots are consistency mechanisms, not version control. Missing files fail explicitly. File indexing
is recoverable after interruption; task deletion retains a retryable tombstone until cleanup succeeds.

## Ownership and affected implementation

- Storage/Database/Chat and Tasks: rounds, request logs, summary coverage and delegation contracts.
- Storage/Database/SQLite: replace schema/adapters; monotonic public keys, constraints and recovery.
- Approved Storage/Database/Workspaces: workspace index contract and filesystem/SQL coordination;
  compiled into existing StorageDatabase target. Files retains only generic sandbox/file primitives.
- Actions/Artifacts: remove persisted versions/restore-version tools, use current workspace and
  transient render/export snapshots; preserve editing validation and explicit render.
- Agents history adapters and model producers: preserve full request evidence and lifecycle boundaries.
- Storage Cache/Support/Media: discoverable container/identity files and accurate shared-media names.
- Update Package dependencies, tests, module READMEs and overall cross-module design after implementation.

## Validation

Cover round/request reconstruction, source isolation, valid/stale summaries, full long JSON and tools,
new/resumed/cancelled/replaced delegations and late-event fences, source deletion, filesystem CRUD/empty
files/failed writes/index recovery, snapshots and exports. Run scripts/check.sh and scripts/build-ios.sh.
Record automated/build results separately from simulator, device and real-model acceptance. Do not
clear physical-device data as a validation shortcut. No new model-output or observation-size limits.

## Execution tracking

Implementation and validation are in progress. This document records intended behavior; implemented
technical contracts belong in MobileHarness READMEs. No model scheduling or context policy redesign.

## Foundation boundary correction

ModelKit must not gain history/evidence/audit hooks for application persistence. Request/response
recording belongs entirely to Agents, using existing ChatRequest and ChatEvent contracts. Remove the
experimental ChatProtocolEvidence type and provider interception. Logs preserve the complete request
submitted by the Agent, all events exposed by ModelKit, parsed text/calls/results and execution errors.
They do not claim to contain raw HTTP/SSE, provider-internal reasoning or adapter configuration that
ModelKit does not expose. This distinction must be explicit in current documentation and validation.

## Implemented scope and remaining acceptance

The ten-table backend, shared round/request projections, Assistant summary coverage, Writer delegation
receipts, current filesystem workspaces, directory/file ownership cleanup and Agent-owned request
recording are implemented. Replaced evidence/chunk/version/index implementations and tools were
removed. Technical contracts were updated; no new compiled target was added. Automated and build
evidence, intermediate failures and unavailable native UI/phone/real-model acceptance are tracked in
[validation](../validation/Storage-Database-Refactor.md). This requirement remains here until its native
acceptance conditions are completed; it is not prematurely archived.

Final automated check and all four iOS builds passed. Native simulator UI, physical-device and real-model acceptance remain explicitly unverified; see the validation report for the stopped simulator installation attempt.

## Foreground startTask persistence regression — 2026-11-05

Device build 2026110508 reproduced a photo-task failure: a request was reserved under an unassigned
round, then startTask assigned that same in-flight request to a new foreground task. SQLite selected
a different segment and rejected its already-reserved request identity. Fix SQLiteChatRepository to
atomically transfer a previously unassigned request into its task segment, preserving its request UUID
and request_N address, earlier unassigned requests, input identity, media references and raw evidence.
Do not permit cross-owner/input transfer or reassignment between established tasks. Recompute old/new
round aggregates and invalidate summary coverage. Unanswered-input queries must consider all segments
of the same logical input, so an empty source segment is not a new pending input. No schema reset,
ModelKit changes, dropped persistence errors or blind retries.

Add a regression using the actual Assistant XML/Skill/foreground-task pipeline with SQLite, plus
reserved-identity transfer, multiple task segments, stale/foreign reassignment and archive coverage.
Investigate the preceding missingRecord independently; do not assume every screenshot issue shares
the same cause. Device inspection uses a read-only local copy, not device database mutation.

The preceding missingRecord has a separate reproducible cause: Writer probes an unaccepted delegation
with a strict joined-task fetch and suppresses its error with try?. Add a lightweight nullable delegation
status query over the existing row and use it for duplicate/terminal admission checks. Pending requested
rows are normal, not storage failures; actual SQL failures still propagate. No error-report suppression
or generic retry is added.

## Photo continuation and history-image regression (2026-11-06)

Device read-only evidence confirms the new photo Task waits for user input, all four model requests
completed, and the last request contains one valid image reference. The referenced JPEG exists with
matching durable media ownership and size. Preserve the device data; this is not a missing model input.

Inspect and correct reply occupancy acknowledgments in Agents/Support/Chat: complete snapshots must
retain the latest final-speech acknowledgment for that interaction session across subsequent text,
Writer and runtime inputs. A newer snapshot must not replace it with an unrelated root and strand
SpeechPerception's pending-final gate when messages are delivered out of order. Keep consent and
playback barriers in their current owners; do not force listening after user-off or use a timer.
Add a reordered multi-input regression and the photography SQLite flow with reply-activity coverage.

History thumbnails in UI/Settings need a stable asynchronous-load owner independent of conditional
placeholder/image children, an explicit fixed preview footprint, and visible missing/read/decode
failure with retry. Cancellation must not commit an empty successful row. Keep source/input checks
in Actions/History and StorageMedia; do not substitute arbitrary album images. Test durable history
projection plus image reads and missing/failure outcomes. Update owning technical READMEs after fixes.

## Reply listening remains paused on device (2026-11-06)

Build 2026110602 still reproduces no next ASR/spectrum after the photo question; explicit off/on restores
input. The prior acknowledgment regression fix is valid but did not establish this device's root cause.
Existing device AppLifecycle debug logs redact entire state text. Add low-frequency, content-free OSLog
checkpoints owned by SpeechPerception and Actions/Speech/Listening, covering reply-policy counts,
pending-final/capture/admission gates, resume start/join/reset/end, Action revision/playback barriers and
failure/cancellation. No raw speech, photo, key, model payload or per-PCM logs; no new table or directory.
Use the live device trace to identify the actual gate before another behavioral workaround. Check the
clearReply onset entry and startup feedback separately: pressing alone must not clear captions; current
code emits clear only for speech.phase(speaking). Wake-cue false onset must not be assumed without proof.

Execution-log correction: UI.Caption.clearReply is an Agent-owned internal presentation Action. Extend
the existing Agents ActionActivityPresentation internal-path projection and its regression coverage;
normal successful rows are hidden unless internal actions are enabled. Preserve visibility of actual
failures under the existing diagnostic policy. Do not classify in UI by Writer/Assistant business names.

### Confirmed live cause and correction

The 01:08:34–01:08:58 device trace shows final ASR acknowledged, playback draining normally, but
Assistant occupancy increases to two during foreground-task island presentation. Genuine final reply
ends with inputs=1 in the speech session; a later inputs=0 snapshot belongs to the independent island
session and is rejected by the speech session fence. SQLite has only one genuine input for that flow.
AgentIslandPublication uses consumer.executeReturning, but ToolDispatcher also sends the same return
through InputGateway. Unpaired toolResult is then admitted as an Assistant input, creating the phantom
occupancy. Fix Agents' producer-bound direct-return route: executeReturning returns native results only
to its caller; ordinary model-round calls keep existing InputGateway result delivery and pairing. Do
not weaken SpeechPerception session/consent validation or wake after every ReACT round. Keep errors,
execution evidence and Action authorization. Add direct-return non-delivery and island-during-ReACT
regressions, plus normal native-feedback coverage. No foundational module design change is required.

User correction: internal presentation MUST still execute through Gateway. The earlier direct-port
proposal is superseded and is not implemented. Add a producer-bound internal-completion execution
mode in the existing Agents Gateway adapter, authorized only for declared internal native tools and
outside model rounds. It returns actual completion/failure to the internal caller and suppresses
InputGateway ToolResult delivery. Assistant/Writer island publication use that mode. Existing
execute/executeReturning model/state-machine feedback behavior remains compatible. Assistant rejects
unpaired native ToolResult rather than admitting it as a new user/reply input. Audit internal captions,
transcript, voice-state and reply-waiting paths for whether results can enter model feedback or ReACT;
preserve the runtime's completion/playback barriers and normal LLM Action/Tool feedback. Gateway and
foundation ownership stay unchanged; no new direct bypass or caller-controlled authorization is added.

Internal runtime Action receipts still synchronize actual execution and playback; they must not become
model observations or cause a ReACT request. Mark them using the producer's declared internal Action/
Tool grants when constructing the round journal/continuation. Internal execution failures remain real
runtime failures with preserved evidence, rather than asking the LLM to repair presentation. Input-onset
clearReply emitted during another model round must not attach to that unrelated round's call ledger.

Internal-log audit includes Caption begin/clear/print/transcript/seal, reply-waiting, voice-state,
Listening.update and Island present/update/end/presentation. Extend the existing path-based business
projection for these runtime-owned operations; cover the common default-hide / explicit-show / failure-
visible behavior. Model business functions such as camera/window controls remain ordinary records.

Update the two parser tests that previously submitted an arbitrary unpaired ToolResult as literal
Assistant input: that obsolete behavior is precisely the rejected path. Verify unpaired-result denial,
and verify parser recovery with a genuine new user turn and second model response instead. Preserve
native paired-result injection/data handling tests independently.
