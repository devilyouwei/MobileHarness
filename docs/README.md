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

✅ Architecture and Roadmap describe the opt-in raw LLM inspection page and its boundary from business execution. ❌ Its parser preview does not establish physical-device or scheduler acceptance.


✅ [ADR 0059](adr/0059-structured-wait-scheduling.md) records nested wait synchronization, task-local queues and the removal of implicit main. ❌ Live-model and device acceptance remain separate from compile/test evidence.
