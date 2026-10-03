# Project documentation

## Requirements and public explanations

| Document | Purpose |
| --- | --- |
| [Requirements](Requirements.md) | Product goals, user scenarios, expected behavior and scope boundaries. |
| [Concepts](Concepts.md) | Biological analogy and vocabulary for Agents, capabilities, communication, Actions and Tools. |
| [Architecture](Architecture.md) | Public explanation of the current system and ownership boundaries. |
| [Platform boundaries](Platform-Boundaries.md) | Foreground/device capabilities and physical-control constraints. |
| [Roadmap](Roadmap.md) | Current delivery priorities, unimplemented directions and acceptance work. |
| [Photographer proposal](Photographer-Proposal.md) | Proposed camera composition/motion behavior; not an implemented Agent. |

## Current technical design

| Location | Owns |
| --- | --- |
| [MobileHarness/README.md](../MobileHarness/README.md) | Overall architecture, directory/target dependencies and complete cross-module technical flows. |
| `MobileHarness/<module>/README.md` | Current module responsibilities, interfaces, algorithms, limits and lifecycle/failure contracts. |
| Nested module READMEs | Domain-specific values, callable entries, adapters and processing policies. |

## Experiments, tests and acceptance

| Evidence | Scope |
| --- | --- |
| [Validation history](Validation-History.md) | Dated repository, build, packaging and installation observations. |
| [Voice acceptance guide](Voice.md) | Reproduction steps and full conversation acceptance criteria. |
| [MOSS validation](Moss-Validation.md) | Synthesis experiments, timings and playback investigations. |
| [Nemotron validation](Nemotron-Validation.md) / [Silero validation](Silero-Validation.md) | Recognition/VAD experiments and their recorded environments. |
| [NexArm physical acceptance](NexArm_Physical_Acceptance.md) | Supervised physical trials and failure investigations. |
| [Measurements](measurements/README.md) | Raw retained device measurement data and interpretation constraints. |
| [Kokoro validation](Kokoro-Validation.md) / [Audio8 validation](Audio8-Validation.md) / [Bootstrap validation](Bootstrap-Validation.md) | Historical model/bootstrap experiments; not evidence for the current default pipeline. |

## Decisions and history

| Record | Purpose |
| --- | --- |
| [ADR index](adr/README.md) | Dated decisions, rationale and supersession. |
| [Change log](Change-Log.md) | Dated project/documentation changes. |
| [Milestone history](Milestone-History.md) | Earlier implementation milestones and their contemporary evidence. |
| [Documentation history](Documentation-History.md) | Archived notes formerly accumulated in current entry pages. |
| [Historical technical baseline](Tech_Design.md) | Original Markdown design, retained as historical source material. |
| [Original Word design](Technical_Design.docx) | Preserved original design source. |
| [License notices](licenses/README.md) | Third-party notices and redistribution information. |

## Documentation ownership

Requirements describe desired outcomes; concepts explain vocabulary; public architecture describes current collaboration. Current technical contracts live in source READMEs. Roadmap describes pending work rather than the history of every change.

Put changes/rationale in the change log or an ADR. Put experimental measurements, test results and installation observations in evidence documents with date, environment, method and scope. Earlier results remain historical after a model, implementation or device change. Preserve original reports and raw data; link them rather than copying measurements into current design pages.

✅ Requirements, concepts, current design, proposals, evidence, history and notices have separate entry points.

❌ Undelivered proposals and unrecorded acceptance are not current implementation claims.

✅ [ADR0100](adr/0100-camera-control-tools.md) records foreground Camera Tool ownership, completion and lease policy; native Tool transport and physical camera acceptance remain pending.

✅ [ADR0103](adr/0103-agent-failure-isolation.md) defines Agent isolation, bounded delivery/execution outcomes and Photographer offline suppression. ❌ Physical fault acceptance remains pending.

✅ Latest main-sh incremental Photographer tracking is integrated through [ADR0102](adr/0102-photographer-aim.md), preserving main’s module boundaries and failure isolation. ❌ Physical smoothness acceptance remains pending.

✅ [ADR0104](adr/0104-expression-perform-and-state.md) documents finite expression and persistent base-state contracts; physical visual acceptance remains on the Roadmap.

✅ Conversation Tool history and usage contract: [ADR0106](adr/0106-conversation-tool-diagnostics.md); physical-provider/UI acceptance remains outstanding.

✅ Audio8 validation remains a historical record; its unused provisioning profile/wrapper was removed during local model cleanup. Mac real-model test fixtures remain retained; shared production source ownership is documented in Resources/Models.

✅ Model-resource documentation audit (2026-10-03): current READMEs describe source declarations, metadata-only builds, sandbox receipts, explicit voice warmup and HF foreground/ZIP background limits. Older model packaging/default-provider ADRs and validation reports are explicitly historical and point to ADR0105/current module contracts; original Technical_Design.docx remains unchanged.

✅ Architecture, Roadmap and ADR0105 distinguish successful model publication from task-record persistence failure and describe the targeted Storage policy. ❌ Phone incident attribution is not claimed from isolated regression tests.

✅ [Shared multilingual Nemotron Core ML runtime](adr/0107-nemotron-coreml-multilingual.md).

✅ Architecture and Roadmap document nonterminal model-call resolution failures and shared output result retention. ❌ Live-model acceptance remains pending.

✅ ADR0103 failure isolation refinement: retained Action reports preserve later exceptions; invocation/resource rejection is call-local; Tools distinguish execution and feedback failures, with joined cooperative deadlines and task-scoped cancellation. ❌ Uncooperative handlers and physical acceptance remain outstanding.

✅ Directory contract audit reconciles Tools, Gateway dispatch/routing/results/validation, Agent generation/output/history and App lifecycle documentation with ADR0103. ❌ Live-provider/device acceptance remains separate from documentation and unit validation.

✅ Function-defined timeout takes precedence over Runtime defaults: Action keeps request-dependent budget resolvers (including NexArm); Tool stores optional Duration in its definition/registry and @Tool factories. Unspecified Actions/Tools use30 seconds; invalid explicit declarations fail without fallback. ❌ Deadlines cannot forcibly interrupt uncooperative cleanup.
