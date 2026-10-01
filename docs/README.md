# Project documentation

Purpose: collect project requirements, public technical explanations, change history, test evidence, delivery plans, future proposals, original design sources and required license notices without duplicating current module implementation contracts. Design goals: help readers distinguish what works now, what was decided earlier and what still needs acceptance.

## Documentation ownership

| Location | Owns | Does not own |
| --- | --- | --- |
| [MobileHarness/README.md](../MobileHarness/README.md) | Target technical plan, module map and cross-module design rules | Detailed queue algorithms or per-module API contracts |
| `MobileHarness/<module>/README.md` | Current module purpose, design goals, implemented/outstanding behavior, exact limits, failure and lifecycle contracts | Project requirements, change logs or speculative designs |
| `docs/` requirements and public explanations | Product goals, user scenarios, externally understandable capabilities and system-level explanation | Code-level implementation contracts |
| [Architecture.md](Architecture.md) | Current dependency direction and end-to-end ownership across modules, written for readers outside a single module | Copies of module parameters or dated implementation journals |
| [Roadmap.md](Roadmap.md) and future proposals | Milestone status, planned features, unimplemented technical options and acceptance state | A second implementation specification or an implied claim of implementation |
| [ADR index](adr/README.md) and change records | Why and when a decision or contract changed; supersession links | The sole source for today's exact API/limit values |
| Validation reports, including [Voice.md](Voice.md) | Reproducible checks, raw measurements, observations and device acceptance criteria | Module design or implementation details |

When a runtime contract changes, update the owning module README first, then the affected project-level boundary, decision/change record and roadmap. Link to the module README instead of copying its limits into another current document. Mark future ideas as **proposed**, delivered behavior as **implemented**, and measurements with date, environment and method. A proposal in `docs/` does not authorize a code directory or become a current contract. Keep dated ADRs and validation reports as historical evidence, clearly linking a superseding decision when needed.

✅ Current entry points: [technical plan and source map](../MobileHarness/README.md), [public architecture](Architecture.md), [roadmap](Roadmap.md), [Photographer proposal](Photographer-Proposal.md), [decisions](adr/README.md), [change history](Change-Log.md), [test records](Validation-History.md) and [voice acceptance](Voice.md). [Storage](../MobileHarness/Storage/README.md) and [StorageAudio](../MobileHarness/Storage/Audio/README.md) own the current memory/PCM contracts. Existing dated validation reports remain under `docs/`.

❌ A unified project requirements document and a dedicated proposal index have not yet been created; the current [Photographer proposal](Photographer-Proposal.md) is linked directly until there are enough proposals to index. Historical reports are not automatically current after model or prompt changes. The original `Technical_Design.docx` and historical `Tech_Design.md` remain source material, not current module specifications.

✅ [ADR 0057](adr/0057-local-settings-storage.md) records local document cache/persistence synchronization and user-settings migration. ❌ Cross-device synchronization remains deferred.


✅ [MOSS validation](Moss-Validation.md) records replacement-model setup and evidence; [ADR 0058](adr/0058-moss-tts-nano.md) records the default change. ❌ Device acceptance is separate from build and Mac checks.

✅ ADR 0053 records optional cloud credentials and endpoint defaults. ❌ Live provider acceptance remains pending.

✅ Architecture and Roadmap describe the persistent conversation-history page, which supersedes the standalone raw-output test. It records real Assistant traffic; historical parser preview never executes Actions. ❌ Its preview does not establish physical-device or scheduler acceptance.


✅ [ADR 0059](adr/0059-structured-wait-scheduling.md) records nested wait synchronization, task-local queues and the removal of implicit main. ❌ Live-model and device acceptance remain separate from compile/test evidence.

✅ Current generation/output/routing diagrams include typed wait boundaries. The [historical technical baseline](Tech_Design.md) and ADR 0015 explicitly point to the replacement scheduling rules; their original algorithms remain historical evidence. The Channel lock section is a future ownership proposal, not current wait behavior.

✅ [ADR 0060](adr/0060-persistent-conversation-history.md) records durable current/past conversations, ten-round context and archived-title generation. ❌ Earlier in-memory conversations are not recoverable.

✅ [ADR 0061](adr/0061-agent-json-v5.md) defines the current JSON v5 model catalog and code-owned internal permissions. Older ADRs describe historical schemas where marked superseded. ❌ Full native Tool schemas/streaming remain future work.

✅ [ADR 0062](adr/0062-default-chat-output-budget.md) documents optional output budgets and default-provider behavior.

✅ [模块目录整合](adr/0063-module-directory-consolidation.md) 记录 Runtime 子目录、Agents/Core 编译边界及当时的 App/Views 归属；页面后续迁到独立 UI 模块，见 ADR 0064。

- [ADR 0064 — App and UI boundaries](adr/0064-app-ui-boundaries.md): explicit composition, independently compiled pages and application workflows.

✅ [ADR 0065](adr/0065-action-runtime-contracts.md) and [Actions/Runtime](../MobileHarness/Actions/Runtime/README.md) record the implemented Action contract stage and its limits. ❌ Ongoing activity owners, persistent resource enforcement and execution deadlines remain future work.

## Action runtime stage 2

✅ [ADR 0066](adr/0066-action-results-resource-leases.md) supersedes the stage-1 future-work entries for Action terminal feedback and resource arbitration. Detailed contracts live in Gateway/Output/Results and Resources. ❌ Durable feedback, generic activity management, audio/robot migration and hardware acceptance remain outstanding.

## Behavior module assembly

✅ [ADR 0067](adr/0067-domain-owned-behavior-assembly.md) and the BehaviorAssembly README describe ownership and extension rules. ❌ Automatic discovery and universal device capabilities are not supplied.

## Canonical Action entry audit

✅ [ADR 0068](adr/0068-canonical-action-entrypoints.md) records the Action implementation audit and typed speech capability migration. ❌ Physical-device acceptance remains outstanding.

## Storage core/domain layout

✅ [ADR 0069](adr/0069-storage-core-domain-layout.md) records the Storage core/domain split and no-data-migration guarantee.

❌ Image/video/semantic-memory storage and cross-device synchronization remain planned.
