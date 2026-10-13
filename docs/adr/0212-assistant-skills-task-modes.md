# ADR0212 — Assistant Skills and local task modes

Status: ✅ implemented; physical-device acceptance pending.

Assistant owns all user conversation and composes pure resource Skills into one foreground task mode. Deterministic and streaming Agents retain their independent execution/state ownership. Skill configuration references canonical Actions metadata; Agent fixed function declarations and per-request Skill catalogs are distinct. Immutable snapshots preserve historical authorization. send remains an admission-confirmed Action; publish remains one-way.

Resources/agents, Resources/skills and Resources/task-modes are explicitly approved by the user. Skills contain configuration and instructions only. Bundled catalog paths are explicit and confined. First version has no remote loading or task stack. Active task must complete or cancel before another specialized task begins. Model completion leaves a task waiting for user input; explicit terminal control closes after round cleanup.

Assistant tasks retain Skill versions, request catalogs, calls/results and ReACT evidence. 历史记录 exposes only Assistant 聊天记录 and 任务记录; fixed specialists persist task/transaction state only.

Validation: dynamic permission/alias/conflict and dependency bounds, snapshot isolation, photography multi-input continuation, cancellation/restart/write-failure, current request read/export, Channel serialization and actual device state. Run scripts/check.sh and scripts/build-ios.sh; physical camera/audio acceptance is separate.

Canonical function metadata is packaged in the dependency-free FunctionContracts target, consumed by Agents without importing concrete Actions. App injects actual functions/control endpoints; Gateway validates fixed calls or immutable effective round catalogs. Asset validation uses bounded immutable caches to keep high-concurrency input deadlines from expiring.

Evidence: [validation record](../Validation-History.md#2026-10-11--assistant-skills-and-task-modes). Full check and focused controls passed; generic iPhone build and exact asset packaging passed. Simulator CoreAI dependency and real-device/model acceptance remain limitations.

## 2026-10-11 修订：泛化目标与 Skill 组合

✅ 已实施。固定模式不再约束业务目标。Task 与 Skill 独立，startTask 可复用原子 Skill 加载；一个前台任务与独立后台任务。后台保留 send 确认与显式终态，不自动抢占、推理或播放。默认临时能力归属决策链，任务能力归属任务。基础能力常驻。目录仅移除已授权的 task-modes，不新增目录或依赖。

❌ 本版仍需真实模型、原生 UI 与真机验收；后台仅公共机制和合成执行者，无新增真实业务。自动检查证据见 Validation-History.md。

Generic Task/Skill validation: [Validation history](../Validation-History.md#2026-10-11---generic-tasks-and-independent-skill-scopes).


## Shared asset location and Bundle lookup (2026-10-11)

Pure Agent and Skill assets now reside in MobileHarness/Resources/agents and skills, with catalog.json at the shared root. Agents retains schema/loading policy and compiles only its own sources; its SPM target copies the explicit asset groups. Runtime locates catalog.json through Bundle.url(forResource:withExtension:) and derives the root from the located file. Appending Resources to resourceURL duplicated the path on iOS and blocked App runtime creation, including camera startup. Flat/Resources-containing bundle regression and missing catalog failure cover lookup semantics; physical acceptance remains separate.


## Task completion and prompt scoping correction (2026-10-11)

The five Task/Skill control functions are finite committed transactions returning values. The state function kind accepts completed-only acknowledgments and cannot represent these results; changing the canonical registration preserves strict executor validation and prevents a committed transition from being misreported as invalidCompletion.

Retained delegation/task views belong to history, not system instructions. Request data includes same-session live background tasks or the exact directed task only (at most 17). Legacy terminal delegation views are excluded; local completion summaries must belong to the current input. System messages contain policy and loaded Skill instructions, never retained task reports. Full historical data remains available to UI/history queries.


## Source organization revision (2026-10-11)

Asset filenames/directories are now UpperCamelCase under Resources/Agents and Resources/Skills; Catalog.json remains the explicit index of unchanged runtime IDs. AgentConfigurations/AgentSkillLoader moved to Support root; AgentTaskSkillState (type-only rename) and AgentFixedTaskCoordinator moved to Context. Communication has only message contracts and input parsing. Assistant-specific passive camera reduction and data-message building moved from the shared Chat actor to Assistant hooks/Builder. Xcode navigation is synchronized, without extra target/resource membership. Static checks protect source names, resource paths, shared role neutrality and component placement.


## 2026-10-11 revision: Skill-owned business functions

✅ Removed Permissions.json and per-Agent business allowlists. Loaded Skills directly define model-callable functions. Agent.json functions retain only fixed controls/workflow declarations. Gateway uses the captured round catalog for model calls; descriptor capabilities apply to fixed calls. Communication rights, executor identity, task scope, canonical schemas, conflicts and bounded composition remain checked. App checks implementation coverage for each bundled Skill independently, avoiding a combined global whitelist.

## Task controls use Action Calls (2026-10-12)

BasicSkill registers the five Agent.Task controls as Actions on Control Channel. App exposes the same finite implementations through ChannelScheduler; trusted fixed callers still reuse TaskControlCapability. Start/load/release produce observation feedback and rebuild the immutable request catalog after the result barrier. Finish/cancel record the terminal transition and join the round/reply cleanup before restoring defaults. Native Task-specific worker dispatch is removed. Photography functions remain Camera Channel Actions; read-only history queries remain native Tools.

This protocol choice makes orchestration visible in Action logs and uses one scheduling/result path. It does not imply native Tools cannot support continuation, nor guarantee a model will always choose the required next action. Skill instructions require concrete progress after loading and distinguish genuine user waiting from narration-only readiness. Regression acceptance requires actual capture/save invocations rather than successful prose or a loaded Skill.

## Separate generation and execution deadlines (2026-10-12)

The Chat decision budget charges only model collection/interpretation and short output admission. Action completion, playback, context assembly and queued continuation waits are excluded from the cumulative 30-second generation limit. Four requests and sixteen native calls remain cumulative. The round receipt has its own 60-second bound; each Action keeps its own execution timeout. Generation and execution-feedback timeouts are distinct failures. A timeout already reported by the generation timer retains that cause when elapsed-time accounting exceeds the budget. Completed effects are recorded, never replayed automatically.


## Amendment: Agent request failures as bounded retry observations (2026-10-12)

Chat/provider failures (including HTTP status errors), output parsing failures and observation construction errors can continue the same decision with explicit failure evidence. Failed model attempts retain their original error/state without completing the user input or dropping its Task. Seal/join accepted effects before a retry and preserve native call/result pairing; incomplete output is data, never replayed. The next request receives the failure, partial output and actual outcomes. Retries share the four-request, native/call/feedback and cumulative generation budgets and keep the same provider binding. Cancellation, closed lifecycle, exhausted budgets, persistence failure or unconfirmed feedback terminates explicitly. Terminal Task controls do not reopen a closed goal.

## Replace Agent time budgets with lifecycle ownership (2026-10-12)

The user's revised contract supersedes the separate 30/60-second design above. There is no Agent generation, queued-input, feedback-barrier, ASR/TTS, native audio startup/finish or speech-cache timer. Inputs have no implicit deadline and communication contracts no longer assign TTLs. Explicit perception-data freshness remains separate from conversation lifetime. Natural network errors/timeouts are provider-owned. Only functions declaring timeout/estimatingDuration have execution deadlines; FunctionExecutor/ToolExecutor supply no fallback. Function timeouts preserve actual outcomes and return through ActionResult.

Audio completion requires real provider/player callbacks. Owner cancellation, failure and turn/session retirement clear PCM and bounded error metadata; no timer impersonates completion or cleanup. Reply occupancy is released by actual terminal facts; user stop and failed utterance publication release their own pending-final hold. Request/call/queue/memory capacities remain independent of time. Pending execution results persist until admission or scope/target closure with bounded storage and retry backoff, without TTL/retry-count disposal.
