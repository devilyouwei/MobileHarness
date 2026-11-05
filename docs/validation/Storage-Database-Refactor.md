# Storage database and current Writer workspace validation

## Environment and scope

2026-11-05, macOS arm64, Xcode 27 toolchain. Requirement: [Storage database refactor](../requirements/Storage-Database-Refactor.md).
One shared development database, ten domain tables, current filesystem workspaces without retained
versions, and Agent-owned model request logging. Initial implementation validation made no production-
provider call, credential edit, physical phone install, manual phone SQLite clearing or data export.
The subsequently requested physical-device installation is recorded at the end of this report.

## Implemented evidence boundaries

- ModelKit has no added recording type, request field, audit callback or HTTP/SSE interception.
  The experimental ChatProtocolEvidence implementation was removed following the foundation-boundary
  correction. Existing, previously authorized ModelKit inference/output-limit changes in the working
  tree were preserved, not reverted along with this experiment.
- Agents records complete submitted ChatRequest parameters/messages/tools and exposed ChatEvents.
  Native calls, received text, usage, termination, errors and subsequent local tool outcomes remain
  distinguishable. Dynamic system/State is in request logs, not ordinary round metadata. Raw HTTP/SSE,
  provider-internal reasoning and adapter options absent from the model API are not claimed as evidence.
- messages physically stores a round/foreground-task segment; role-based MessageRecord values are
  current read projections, not an old-schema compatibility layer. New-request admission invalidates
  an older Task summary before any token arrives; originals remain available when coverage is stale.
- Source files live at writer/task_N/relative-path. workspace_files contains only file metadata. Current
  UUID tokens and SQL write leases fence writes; they do not address retained versions. Crash recovery
  repairs explicitly interrupted file indexes; missing accepted/draft files fail instead of being recreated
  from model logs. Deleting a Writer task preserves Assistant report logs by nulling their delegation FK.

## Automated scenarios

StorageSchemaTests / WorkspaceRepositoryTests exercise:

- Exactly ten tables and foreign-key consistency; no chunk/source-version/notification side tables.
- Multiple requests within one round, dynamic system exclusion from ordinary messages, complete
  request restoration, and raw pagination over sixty rounds with two requests each.
- Long native arguments in Agent request recording with no independent output/argument truncation.
- Current-file replacement/deletion, empty source files, large multi-file collections, SQLite reopen,
  concurrent writer rejection, task ownership, non-reused task numbers and active deletion rejection.
- Interrupted index repair, missing-file errors and retryable cleanup after sandbox/symlink failure.
- Preservation of Assistant report request evidence after deletion of the associated Writer workspace.

Existing suites cover new/resumed assignments, cancellation/replacement, notification rejection and
redelivery, Agent isolation, foreground summary fold/expand, archive deletion, native tool results,
Window lifecycle, file previews and PDF/ZIP logic. Direct SDK recording was replaced with Agent-layer
recording; six targeted regressions passed after that correction.

## Check and build runs

Final results: scripts/check.sh exited 0 on the final idle run, and scripts/build-ios.sh exited 0
with all four schemes and both resource checks passing. IntegrationTests: 1045 passed; UI unit tests:
176 passed; LiveRuntimeTests: 227 passed. Strict formatting, module boundaries, Python checks and
plist checks passed. git diff --check passed. Intermediate runs are retained as failure evidence,
not counted as final passes:

- `/tmp/storage-refactor-check3.log`: identified old empty-request-header expectations, missing user
  acceptance projection, and a two-database Writer fixture; all were corrected.
- `/tmp/storage-refactor-final-check.log`: old readiness/header assertions and native state/timeout
  failures under concurrent host load; corrected storage assertions and separately reran native cases.
- `/tmp/storage-refactor-acceptance-check.log`: full script passed before the ModelKit ownership
  correction; IntegrationTests 1043 and LiveRuntimeTests 227 passed. This is not the final boundary result.
- `/tmp/storage-refactor-final-boundary-check.log`: three unrelated native seeding/tracking/timeout
  failures under concurrent build load. No unrelated production modules were changed to mask them.
- `/tmp/storage-refactor-agent-recording.log`: six Agent-recording/storage regressions passed.
- `/tmp/storage-refactor-final-idle-check.log`: final script exit 0, with no concurrent simulator boot; includes the foundation-boundary correction and summary-admission regression.
- `/tmp/storage-refactor-release-build-ios.log`: final script exit 0; MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero all built, with 30 Skill resources and Live Activity bundle validation.

The NativePresentation helper starts its camera/Metal acceptance case without a complete final case
report in the existing runner. A check-script exit status is not a claim of complete native UI acceptance.

## Native simulator, phone and real-model limits

A deterministic synthetic Writer SQLite/workspace fixture was generated successfully by
storageSyntheticWriterUIFixture. The new isolated simulator `Storage Refactor Acceptance` was created,
but simctl installation did not return while its first boot and host builds were active. That attempt was
terminated and the isolated simulator shut down. No WriterRecordsNativeAcceptance assertions ran;
list navigation, native preview and actual share-sheet/PDF/ZIP acceptance remain unverified for this build.
The fixture is synthetic, not a real model result. Physical-device speech/Writer and real-provider
acceptance were not run. Device data remains unchanged; the approved development schema rebuild
will take effect only when the new application opens an older-format database.

## Requested physical-device installation — 2026-11-05

At the user's request, the current tree was built for iPhone 17 Pro as 0.1.0 (2026110508).
`/tmp/storage-refactor-device-build.log` reports BUILD SUCCEEDED. Strict/deep signing verification,
30 packaged Skill resources and the embedded Live Activity checks passed. Covered installation
succeeded, receipt sequence 5972 (`/tmp/storage-refactor-device-install.json`). Fresh launch with
terminate-existing succeeded (`/tmp/storage-refactor-device-launch.json`); process 21476 was verified
running from the newly installed bundle, and installed-app metadata confirms build 2026110508.

No uninstall, manual SQLite edit or manual workspace replacement was performed. The approved
schema rebuild is application startup behavior; device SQLite was not extracted to independently
verify it. Installation and process startup do not establish Writer real-model, speech, history UI,
file export or other physical interaction acceptance. The earlier simulator/real-model limits remain.

## 2026-11-05 startTask photo regression

Read-only device SQLite/WAL copy (build 2026110508, quick_check ok, schema 20261107) associates the
23:31 persistence conflict with a photo startTask request reserved before foreground-task attachment.
The existing request UUID remained generating in its unassigned segment; startTask then attempted
insertion into a different segment, violating request uniqueness. The simultaneous Writer assignment
completed; it is not the source of this photo persistence conflict. The preceding missingRecord came
from a strict accepted-delegation fetch used to probe a pending requested assignment.

A deterministic SQLite test reproduced conflict before the fix (`/tmp/starttask-conflict-red-completed.log`).
After transactional reassociation, four focused tests pass (`/tmp/starttask-conflict-regression2.log`):
reserved request transfer with earlier ReACT retained; stable single-request address plus foreign/task
rebinding rejection; pending status and real closed-database failure; actual Assistant XML photography
pipeline using production SQLite adapter (capture, save, repeat capture). Model/camera responses in
these tests are fixtures, not live model or physical camera acceptance. No schema change or device
history deletion is needed for the fix. Raw device evidence is kept out of the repository.

The focused fixes also pass `scripts/check.sh` (`/tmp/starttask-fix-check.log`, exit 0): 1049 integration
tests and 227 LiveRuntimeTests, plus the remaining package tests, boundary, format, Python and plist
checks. NativePresentation still does not provide a complete per-case result in this runner; no new
physical photo interaction or real-provider inference has been performed. Local device SQLite/WAL
copies used for diagnosis were deleted after inspection; the phone database was left unchanged.

`scripts/build-ios.sh` passes all four schemes (`/tmp/starttask-fix-build-ios.log`). The signed device
build also passes (`/tmp/starttask-fix-device-build.log`), including final bundled Agent/Skill assets,
Live Activity contract and deep/strict signature verification. Installed in place on iPhone 17 Pro as
0.1.0 (2026110601), installation receipt sequence 5980, then successfully launched PID 21520. Device app
and process queries confirm the installed version and executable from the new bundle. This verifies
installation/startup only; actual photo/voice acceptance remains separate. No device database reset
or model/provider configuration change was performed.

## 2026-11-06 photo continuation / history thumbnail

Read-only device snapshot after build 2026110601: task_3 is waitingUser; the four photo-related model
requests and playback/Action results completed without a persisted execution error. The last request
retains media_2 imageReferences; SQLite metadata and original JPEG agree, and a device file read succeeds.
This evidence establishes successful capture/model input and excludes a missing JPEG, but does not
persist the live SpeechListeningPolicy state or establish the exact UI cancellation sequence.

A deterministic multi-input regression reproduces a listening race before the fix
(`/tmp/photo-followup-ack-red.log`): the latest complete reply snapshot replaces final-two acknowledgment
with later-text, and a receiver accepting the newest revision retains pendingFinal/paused. Carrying the
latest admitted speech acknowledgment across unrelated publications fixes that regression. Older input
completion cannot roll it back; explicit user-off and playback ownership remain unchanged.

Thumbnail loading now has a stable fixed-size owner; cancellation does not commit empty success, and
missing bytes produce an explicit missingImage failure/retry. File/read/decode and UI lifecycle evidence
are distinct; the phone image was not lost from model history. Temporary local device evidence remains
outside the repository and is deleted after inspection.

Focused final regressions pass (`/tmp/photo-followup-final-regression.log`): SQLite request detail to
Actions history workflow reads the exact original image using the stored source/input association;
queued speech acknowledgment survives newer non-speech snapshots; listening policy combines replies;
photo reader verifies references, bounds admission, releases cancellation and reports missing/failed/
oversized reads. Media bytes in the automated test are a byte-reader fixture, not native JPEG decoding.
The local SQLite/WAL/JPEG copies used for device inspection were deleted; device files were untouched.

`scripts/check.sh` passes for these fixes (`/tmp/photo-followup-check.log`, exit 0), including 1050
integration tests, 227 LiveRuntimeTests and the remaining package suites, boundary/format/Python/plist
checks. This remains automated/fixture evidence: it does not establish physical voice or thumbnail UI
acceptance. NativePresentation does not yield a complete per-case result in the current runner.

All four `scripts/build-ios.sh` schemes pass (`/tmp/photo-followup-build-ios.log`). Signed physical
build passes (`/tmp/photo-followup-device-build.log`); deep/strict signature, packaged 30 Skill assets
and embedded Live Activity checks pass. Installed in place on iPhone 17 Pro as 0.1.0 (2026110602),
receipt sequence 5988; launched PID 21538. Device app/process queries confirm that version and new
executable. No schema reset, device-media deletion, automatic capture or real-model request was used
for acceptance. Physical photo → spoken question → listening continuation and thumbnail display need
user interaction to verify; installation/startup is not that acceptance result.

## 2026-11-06 remaining device listening freeze

User reports build 2026110602 still suppresses next ASR/spectrum, while the iOS microphone indicator
remains active; explicit listening off/on restores recognition. This is not accepted as resolved by
the prior acknowledgment regression. Latest read-only SQLite evidence again records a waiting-user
photo Task and completed model replies; it does not contain the private live listening-policy gates.

Device Console AppLifecycle logs redact state as <private>. Content-free SpeechListening checkpoints
were added in the existing owning Agent/Actions files (no new database, directory or raw media logs).
Focused policy/ASR and internal-action-filter tests pass; clearReply's successful execution now follows
the internal-action filter, with true failures remaining visible. Diagnostic build 2026110603 compiles,
signature verifies and installs, but automatic launch was refused by iOS lock-screen protection.
The user was informed and asked to unlock/open the app before reproducing. Installation alone is not
recorded as successful launch or behavioral acceptance.

### Captured live gate and internal-result ownership

Console captured 28 SpeechListening checkpoints for the 01:08:34–01:08:58 photo flow on diagnostic build
2026110603. Final speech cleared pendingFinal successfully; voice playback reached count=0, but paused
remained true with one occupied source. Assistant occupancy rose from 1 to 2 at task-island admission;
genuine reply completion published inputs=1 in the speech session. A later inputs=0 snapshot was for
the independent presentation session (speechAcknowledged=false), which SpeechPerception correctly
rejected by session. SQLite contains one genuine input for the flow, four completed model requests
and no extra user/Writer input at the point occupancy increased. The stray work was an unpaired native
ToolResult from UI.Island's executeReturning call; that API also delivered it through InputGateway.
The local SQLite/WAL inspection copies are not repository artifacts and are deleted after analysis.

`directIslandResultMustNotBecomeAssistantInputDuringAReply` reproduces the unwanted queued input before
correction (`/tmp/listening-island-feedback-red2.log`). Changing the actual island sender to the
Gateway's producer-bound executeInternal completion mode fixes it. Gateway authorization/execution
remain in place; no direct presentation bypass was implemented. Unpaired Assistant native results are
rejected, and internal presentation acknowledgments/errors cannot request another model turn.

Focused final regressions pass (`/tmp/listening-internal-final-regression.log`): 15 test functions,
including internal native success/failure with no inbox delivery, denial of undeclared/round-bound
internal calls, preservation of ordinary native feedback, island call while Assistant is occupied,
internal caption value/failure without ReACT, plus normal Action/Tool/mixed business-output, failure,
barrier and result-pairing cases. Earlier photo SQLite and clearReply filter regressions also passed.
These are fixtures, not physical voice acceptance. A prior full diagnostics check had one independent
PlatformState seeding timeout/invalidSnapshot failure; its isolated rerun passed. It is not reported
as a clean full-suite pass. The final fix receives a separate full check/build record.

The first full final-fix check completed runtime suites but had four main-suite failures: two timing/
expiry cases under concurrent build load, and two parser tests depending on the deliberately removed
unpaired-ToolResult-as-Assistant-input behavior. The parser tests now verify denial and use a genuine
new user/model turn to test parser recovery. All four pass in isolated rerun
(`/tmp/listening-island-fix-recheck.log`); no production fallback was restored. A separate idle full
check is recorded in `/tmp/listening-island-fix-final-check.log`.

Physical build 2026110604 passes (`/tmp/listening-island-fix-device-build-final.log`), with strict/deep
signature and final Agent/Skill/Live Activity verification. Installed in place, receipt sequence 6004.
The automatic launch was rejected by iOS lock-screen protection; user was informed and asked to open
and test the installed fix. No successful launch or physical acceptance is inferred from installation.

### Physical user acceptance

After manually opening installed build 2026110604, the user tested the requested sequence “帮我拍照 →
final spoken question → directly say 保存” and reported “好了，都好了”. This is physical user-confirmed
photo/voice-continuation acceptance; it is separate from automated fixtures and from the earlier
lock-screen-refused automatic launch. No fresh Console trace was obtained for the fixed run after the
device disconnected, so no new timing/round-count claim is made. The earlier captured trace also places
confirmedOnset/clearReply approximately 2.5 seconds after listening activation in the instructed silent-
then-speak test, rather than at the long-press boundary itself.

Final idle `scripts/check.sh` passes (`/tmp/listening-island-fix-final-check.log`, exit 0): 1053
integration tests, 227 LiveRuntimeTests, remaining package suites, boundary/format/Python/plist checks.
This supersedes neither the earlier failed run nor its recorded causes; it verifies the final source
and updated contract tests without concurrent builds. NativePresentation still lacks a complete
per-case native report in the existing runner. Physical user-confirmed acceptance is recorded above.

Final `scripts/build-ios.sh` also exits 0; all four builds report `BUILD SUCCEEDED`
(`/tmp/listening-island-fix-final-build-ios.log`). The subsequent multi-source input coordination
document is analysis only; no new coordination behavior or native acceptance is claimed.
