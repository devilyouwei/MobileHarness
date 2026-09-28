# Project documentation

Purpose: collect project requirements, public technical explanations, change history, test evidence, delivery plans and future proposals without duplicating current module implementation contracts.

## Documentation ownership

| Location | Owns | Does not own |
| --- | --- | --- |
| [MobileHarness/README.md](../MobileHarness/README.md) | Target technical plan, module map and cross-module design rules | Detailed queue algorithms or per-module API contracts |
| `MobileHarness/<module>/README.md` | Current module purpose, design goals, implemented/outstanding behavior, exact limits, failure and lifecycle contracts | Project requirements, change logs or speculative designs |
| `docs/` requirements and public explanations | Product goals, user scenarios, externally understandable capabilities and system-level explanation | Code-level implementation contracts |
| [Architecture.md](Architecture.md) | Current dependency direction and end-to-end ownership across modules, written for readers outside a single module | Copies of module parameters or dated implementation journals |
| [Repository-Structure.md](Repository-Structure.md) | Physical paths, SwiftPM/Xcode target mapping and documented layout exceptions | Runtime algorithms |
| [Roadmap.md](Roadmap.md) and future proposals | Milestone status, planned features, unimplemented technical options and acceptance state | A second implementation specification or an implied claim of implementation |
| [ADR index](adr/README.md) and change records | Why and when a decision or contract changed; supersession links | The sole source for today's exact API/limit values |
| Validation reports, including [Voice.md](Voice.md) | Reproducible checks, raw measurements, observations and device acceptance criteria | Module design or implementation details |

When a runtime contract changes, update the owning module README first, then the affected project-level boundary, decision/change record and roadmap. Link to the module README instead of copying its limits into another current document. Mark future ideas as **proposed**, delivered behavior as **implemented**, and measurements with date, environment and method. A proposal in `docs/` does not authorize a code directory or become a current contract. Keep dated ADRs and validation reports as historical evidence, clearly linking a superseding decision when needed.

✅ Current entry points: [technical plan](../MobileHarness/README.md), [architecture](Architecture.md), [repository mapping](Repository-Structure.md), [roadmap](Roadmap.md), [decisions and change history](adr/README.md) and [voice acceptance](Voice.md). [Storage](../MobileHarness/Storage/README.md) and [StorageAudio](../MobileHarness/Storage/Audio/README.md) own the current memory/PCM contracts. Existing dated validation reports remain under `docs/`.

❌ A unified project requirements document and a dedicated proposal index have not yet been created; add them when there is real content to maintain, rather than creating empty placeholders. Historical reports are not automatically current after model or prompt changes. Disk cache and persistent storage have no implementation contract yet. The original `Technical_Design.docx` and historical `Tech_Design.md` remain source material, not current module specifications.
