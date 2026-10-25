# Action lifecycle responsibility audit and figure

Date: 2026-10-25. Scope: current registration-to-completion ownership across App, Agents, Gateway and Actions; documentation only.

## Findings

ActionsContainer and its module-owned business assembly register compiled canonical functions, validate binding metadata, expose descriptors and perform preparation/execution. Agents owns the actual producer identity, fixed/effective Skill catalog, Task grants, communication policy and explicit revocation. Gateway coordinates generic endpoint/scope admission, capacity, Channel/wait, resources, cancellation and result delivery through the injected neutral execution port.

Gateway is a project target depending only on FunctionContracts. Its source imports Foundation, Synchronization and FunctionContracts, without AgentCore/Agents imports or role/Skill/Task types. Agent-aware InputGateway, OutputGateway, dispatch/projection adapters and AgentGatewayAssembly compile from Agents. Their file names are not evidence of a reverse Gateway dependency.

ResourceCoordinator still enforces injected generic endpoint policy: allowedOwners on explicit lease acquisition, configured takeover/preemption, lease scope/expiry and live use permits. Agents supplies role takeover policy through opaque values and App wiring. These resource checks must not be conflated with repeated Skill/Task/function authorization. The scope of responsibility is communication and execution coordination, including the admission/cleanup/result infrastructure needed to implement them safely.

The previously identified routing discrepancy remains: ActionCall uses ChannelScheduler; ToolCall uses DirectExecutionDispatcher. Catalog executionPolicy does not currently switch the route. The new figure must describe that behavior and must not claim that all intended routing semantics are complete. See [corrective follow-up](../requirements/technical/Container-Architecture-Followups.md#execution-policy-routing-identified-by-the-overall-readme-audit).

## Documentation changes

Replace the limited route overview in Part III section 7 with a phase-separated registration/configuration, runtime authorization/preparation/scheduling/execution and completion figure. Move the authoritative validation matrix from the UI workflow into this lifecycle section, expanding it to include registration and App lifetime without duplicating module implementation detail. Clarify semantic authorization versus neutral coordination/resource validity and point module READMEs to this cross-module contract.

## Source evidence

- Package.swift: Gateway dependencies = FunctionContracts; existing target boundary checker rejects reverse imports and cognitive types.
- ActionsContainer.configure/prepare/execute, BehaviorAssembly, FunctionRegistry and FunctionExecutor: canonical registration, input/protocol/metadata/budget/resource checks, single-use tickets, current conditions, outputs and joined ownership.
- Agents AgentRuntime/BehaviorCoverage: coverage and public host wiring; OutputGateway/OutputValidator: producer/Skill/Task permission before neutral submission.
- Gateway SignalTransport, ChannelScheduler, DirectExecutionDispatcher, ResourceCoordinator and ActionResultLedger: neutral constraints, preparation delegation, resources, execution joins and bounded immutable result retry.
- App ModuleRegistration: configuration/start order and reverse shutdown without module roots owning each other.

## Verification

- The architecture boundary checker passes on the audited source. Gateway imports only Foundation, Synchronization and FunctionContracts; its project target depends only on FunctionContracts. Host-local log: `/tmp/mh-action-ownership-boundary.log`.
- All 24 overall README Mermaid figures parse and render successfully with Mermaid 11.12.0. The lifecycle figure was visually inspected after shortening participant titles and messages. It uses module-colored groups, separate configuration/request phases, solid requests and dashed returns. The other 23 diagram sources are unchanged from the pre-edit snapshot. Host-local rendering log: `/tmp/mh-action-lifecycle-render.log`.
- Local references/anchors in the affected design and validation documents and `git diff --check` pass. Five retired Gateway-directory links in the historical inventory now retain their original path labels and point separately to the current owner; historical results remain unchanged.
- This is a documentation-only audit. No new full test/build run, real-model, native UI or physical-device acceptance is claimed. The existing execution-policy routing discrepancy remains tracked separately.
