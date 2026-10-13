# Generic Tasks and Independent Skills: Implementation and Migration

Decision: [ADR0212](adr/0212-assistant-skills-task-modes.md). Current contract: [Agents](../MobileHarness/Agents/README.md). Fixed Task Mode resources and old singular Skill controls are removed. No new directory, module or dependency.

| Stage | Result |
| --- | --- |
| Shared mechanisms | Implemented: arbitrary goal, foreground/background execution, batch Skill Actions, stateless SkillLoader, base/decision/task ownership |
| Assistant | Implemented: one foreground Task, isolated history, waitingUser, ReACT, same-chain ownership transfer and terminal cleanup |
| Background library | Implemented: existing send, declared support, admission/progress/result/cancellation, 256 records/16 nonterminal tasks, synthetic executor tests |
| Persistence | Implemented: v1 to v2 interrupted migration; backward-readable execution; task goal/execution and immutable Skill/catalog request evidence |
| UI | Implemented: task presence/goal/Skill ownership and background entry; executor/parent/result history; Action/Task/Agent logs retain active records |
| Physical acceptance | Pending: actual photography/save, speech competition, task switching and native history UI. No real background business is added |

## Runtime and migration

startTask(goal, skills?, execution?) validates and commits foreground task creation plus Skill loading atomically. Background requires target, businessContract and payload and uses communication Action/send. Executor backgroundTasks declarations are support contracts, never new permissions. Production declarations are currently empty; unsupported contracts reject explicitly. Supplemental background send pairs businessContract with payload; cancellation uses scoped send. Delivery acknowledgment is separate from execution completion. Parent completion does not cancel independent background work. Background reports cannot switch foreground, invoke Chat or start playback.

Base Skills stay loaded. Default temporary Skills survive ReACT and expire after the decision chain and reply barrier. Same-chain startTask adopts them; task-owned Skills survive waitingUser and expire after terminal cleanup. Idle fixed loadSkills outside a task rejects instead of creating an ownerless temporary scope. Each user decision chain has its own budget; ReACT does not reset it.

History presents only Assistant conversations and foreground/background tasks. Restart interrupts unfinished Tasks/work and never replays effects. Request catalogs are immutable; late ASR cannot enter a different task.

Evidence: [Validation history](Validation-History.md). Synthetic tests/builds are distinct from physical-device and real-model acceptance.

## Resource packaging correction (2026-10-11)

✅ Agent/Skill assets moved to the existing shared MobileHarness/Resources root. Resolve catalog via Bundle lookup rather than resourceURL + Resources, which duplicates the directory on iOS. Verify real bundle lookup, missing catalog failure and final packaged bytes. Camera failure is investigated independently; no device permission or camera success is inferred from resource validation.


## Source organization audit (2026-10-11)

Reviewed all current non-document source changes, including newly untracked assets. Swift files use UpperCamelCase; Agent/Skill resource directory and filenames now follow the same convention. Runtime identifiers remain lowerCamelCase/kebab-case contracts and are not file naming conventions.

| Owner | Latest change placement |
| --- | --- |
| Actions/Contracts | Neutral ActionDeclaration/ActionParameter values and TaskControlCapability; concrete metadata belongs to each @Action, no Agent policy |
| Actions/System/Support | TaskControlModule, matching existing injected System transaction modules |
| Agents/Support root | AgentConfigurations and AgentSkillLoader: immutable resources/catalog composition |
| Agents/Support/Communication | Message values, contract catalog and input validation only |
| Agents/Support/Context | AgentTaskSkillState, AgentFixedTaskCoordinator and repository |
| Agents/Support/Chat | Generic Chat/Action/Tool/ReACT adaptation; no concrete Assistant casts |
| Agents role directories | Deterministic business policy and Assistant camera/task Context Builder |
| Resources/Agents, Resources/Skills | Pure configuration/prompts, PascalCase paths; stable runtime IDs |
| App adapters/composition/workflows | Capability injection, authority validation and UI projection |
| Storage/Chat | Neutral persisted history/request evidence |
| UI | Presentation values/local interactions; no Agent/runtime dependency |
| Gateway | Input/output authorization and scheduling; no Skill/task business decisions |

No new module/directory/dependency. Type-only AgentSkillState -> AgentTaskSkillState rename preserves serialized keys and versions. Fixed specialists persist task/transaction state only; their obsolete chat schema and history presentation are removed. Shared worker camera handling was moved to role hooks/Builder without changing lifecycle/ordering semantics. Static checks enforce source names, asset paths and these Support boundaries.

## Resource leaf documentation convention (2026-10-11)

✅ Per user instruction, resource Agent/Skill leaf directories have no README. Shared resource contracts belong in Resources/Agents/README.md and Resources/Skills/README.md; Skill.json and Instructions.md remain the complete runtime Skill unit. Code-directory READMEs are unchanged. The 12 leaf READMEs and their Xcode navigation references are removed; runtime configuration and instructions remain unchanged.


## Skill-owned functions (2026-10-11)

✅ Removed per-Agent Permissions assets and maximum-grant intersection. Loaded Skills are the full business Action/Tool catalog; Agent.json functions hold fixed controls/workflow declarations only. Model-round snapshots remain the execution authority; fixed calls keep descriptor validation. Preserve transport permissions, scoped execution and historical evidence. Validate Skill loading without a static business grant, unloaded-call rejection, immutable in-flight catalogs and final packaging.

## 2026-10-11 Skill-owned registration refinement

✅ Implemented: remove Agent.json function registrations, compose baseSkills for all roles, move Task native Tools into permanent BasicSkill, rename BasicInteraction to ExpressionInteraction, move role-specific workflow teaching into Skill instructions, update diagrams and verify immutable catalogs/restart/history ownership. No additional business workers are introduced.


## Camera availability correction (2026-10-13)

✅ Task organizes continuing goals/history; it is not an extra authorization prerequisite for registered camera functions. Assistant no longer validates capture/save/discard against Task/photo owner state or registers captured photos into that state. Capture-only requests can use temporary photography loading and return after confirmed capture. App supplies actual current photo facts and returned image evidence. [Validation evidence](Validation-History.md#2026-10-13--registered-camera-functions-without-task-authorization-and-friendly-recognition-toast) separates fixtures/compilation from device acceptance.
