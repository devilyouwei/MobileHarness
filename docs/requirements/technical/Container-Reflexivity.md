# Container reflexivity and progressive State disclosure

## Goal and constraints

Every module root, child container and important domain owner exposes truthful business/capability, runtime and health facts. Modules retain local types and isolation; no shared protocol, new directory or cross-foundation dependency is introduced. Reflection means explicit descriptors and typed snapshots, never Mirror over private fields. Existing state machines and safety behavior remain authoritative.

State exists independently of Skills. Effective loaded Skills select named, allowlisted projections on each request through AgentSkillLoader.useStates and AgentStateContext. No loadState, model tree discovery, polling, automatic recovery or model wakeup is added. BasicSkill receives a bounded health summary; relevant Skills receive details. Existing source/session/byte limits and request-construction failures remain unchanged.

## Implementation plan

- Add module-local StateSnapshot/StateDescriptor and stateSnapshot/stateDescriptor entry points in existing directories. Separate business, runtime and health; document unknown facts, units, observation time, freshness and session identity. Snapshot reads cannot activate hardware, prepare models, query a device or request permission.
- UI owns effective expression and presentation facts; Actions owns invocation/target/completion semantics. PlatformKit owns native connection and measured motor feedback; Actions owns motion targets and business phases. A target is never used as a measured position. Existing state owners supply snapshots without mutable mirrors.
- Cover Actions execution and retained business services; Gateway scheduling/resources/transport; Agents roles/private Task/Skill summaries; ModelKit root/four child capabilities; PlatformKit root/audio/vision/connectivity; Storage root/cache/files/database; UI root/nine children.
- Compose explicit descriptors and callbacks in App Composition into a recursive internal tree. Stable paths, no global atomics, per-node read failure, cancellation; maximum 256 nodes/depth 16/256 KiB, explicit rejection. The tree is not a model tool. App owns composition only; domain projection remains with owners.
- Preserve current named sources and envelope. Add explicit expression, application diagnostic and health projections; enrich robot facts with actual feedback/age and business motion facts. Role/source registration remains the upper boundary; Skill selection is the per-request disclosure boundary. Internal field additions cannot leak through model projections.
- Health distinguishes healthy/limited/fault/unknown, retains origin and evidence, and does not infer physical damage. No-data is unknown. Cancellation alone is not injury. Read never acknowledges or clears a fault. Recovery requires actual owner evidence. Basic summary has at most eight entries ordered by severity/path and reports omitted count, exposing only capability/severity/impact.
- Update the seven module READMEs, affected nested owner READMEs, App composition, Skills, Agent context/chat documentation and overall cross-module design after implementation. Remove replaced adapters and duplicate mutable state. Preserve unrelated work.

## Acceptance and evidence

Implemented: local snapshot coverage; expression base/override/restoration/cancellation; NexArm target versus telemetry, freshness, disconnect and stale session; runtime/health failure and recovery; tree limits/partial internal errors/zero effects; Skill union/release/field allowlists; cancellation/session/byte error compatibility. Behavioral regressions, scripts/check.sh and all four scripts/build-ios.sh simulator builds passed. Automated/native/model/device evidence is separated in the validation record. Stub success is not physical acceptance.

Implementation is present across the seven roots and child owners, internal tree, explicit metadata, Skill projections and regression coverage. Exact final checks and independent native/model/device acceptance are recorded in [validation](../../validation/Container-Reflexivity.md). Technical READMEs describe only implemented behavior.

### Composition boundary clarification

The existing boundary checker forbids all App JSON encoding because App previously had no generic inspection serialization. Isolate neutral tree erasure in ApplicationStateInspection.swift (existing Composition directory, AppStorage target); permit encoding only there, while retaining all concrete-domain/behavior checks. ServiceFactories only binds typed callbacks. Registry uses registerRoot to distinguish module composition from per-Action registration. No business schema conversion is moved into App. Existing failure journal supplies first/latest occurrence and repeat evidence separately from current health; historical records never imply an active fault.

### Prompt budget constraint

Full regression found that expanded Skill teaching exceeded the existing base/photography UTF-8 budgets. Preserve those budgets and every authorization/control/feedback rule and separate-request example; shorten redundant BasicSkill prose rather than raising limits or weakening safety semantics. Descriptor metadata carries domain meanings, units and finite phase values without expanding model-visible fields.

### Robot projection consistency

The Skill-facing robot read additionally samples the already-owned controller's active target dictionary (maximum six axes). It awaits only that actor, never a device; the connection generation fences a controller replaced during the read. Current measured feedback is sampled afterward and kept distinct from optional business targets/tracking goals. The context read becomes async; existing App ports already await it.

### Public overview alignment

Update the root README and its second diagram, agent-task-skill-action.svg, to show Skill declarations for Actions, States and Instructions. Explain that modules own state while loaded Skills progressively disclose read-only views on each actual request. Align the input/Gateway explanation with direct typed observations and requests, and replace the obsolete simulator-assembly limitation with the implemented explicit simulator variant. This is a documentation/vector-only change; validate links, SVG XML and rendered layout without rebuilding the application. Use “long-horizon agent tasks” in the public overview for multi-step planning and sustained goals; reserve “long-running” for elapsed execution duration.

## Caller-owned State selection correction — 2026-10-31

This supersedes the earlier convenience context-read and App-owned model projections. A module exposes one full stateSnapshot with business/runtime classification in its data. It has no Assistant-specific reader, filtered variant or role switch. Other Agents and internal programs retain full State access through their scoped ports. Business describes domain attributes; queues, worker/registry counts, handle budgets, lifecycle, generation, tracing and renderer mechanics belong to runtime.

Assistant owns named source registration and explicit field selection in Agents/Assistant, using the full state read and only its business data. Skill useStates still selects names each actual request; missing registrations/errors/session generations/byte limits remain explicit. Selection is caller-side and closed over approved fields, including nested values. No runtime-name blacklist, shared foundation protocol, new directory, model tool or persistent fact cache is added.

Affected implementation: reclassify seven module snapshots; enrich their existing business data where current context helpers contain necessary facts (navigation/album, expression, camera, robot and application preparation). Remove Agent camera/device contextSnapshot ports and dedicated encoding helpers; Assistant reads camera/device/platform nodes through the existing complete App inspection read. Move model source assembly into AssistantStateBindings and remove App-to-Assistant health/diagnostic projection callbacks. App binds an unfiltered generic inspection read for caller-owned business capability summaries; original internal diagnostics remain usable. Generic Skill loader and context collector do not acquire Assistant policy.

system.health and system.diagnostics names remain compatible, but Assistant selects only explicit business problem/capability attributes, never root lifecycle or technical fault history. Original internal inspection/diagnostic methods remain engineering interfaces. Classification is not authorization for all Agents: only Assistant LLM State selection is restricted. Existing UI/domain context utilities required for page rendering or non-LLM workflows remain in their original responsibilities.

Validation: business/runtime inventory and retention tests, Assistant field/nested-field non-disclosure under added runtime data, unchanged other-consumer full reads, Skill selection/session/cancellation/byte behavior, authoritative robot targets versus feedback, existing native/device safety regression. Run scripts/check.sh and scripts/build-ios.sh; update owning READMEs and validation evidence. No physical-device or real-model claim follows from stubs/builds.

实现收敛：Assistant 的全部 State 来源统一绑定 App 已有 inspection.snapshot(path:) 的完整无过滤结果，App 仅注入该读取能力；不再需要 camera/device 的 Context 端口，删除对应装配编码与容器 convenience。PlatformStateReading 保留原生内部调用语义，Assistant 使用同一完整 State 树，不新增第二套接口。Navigation 的统一 State 包含其关联相册的页面内容与操作事实。

清理范围补充：删除已无生产调用的 AgentPlatformState 透传适配器与 AgentContainer.platformState 注入，改用现有统一读取链路的原生事实回归测试；同步 Xcode 文件组与架构检查的过期白名单。

测试夹具的原生来源注册也走 AssistantStateBindings 的具名注册选择；保留确定性原生样本，避免测试继续依赖已删除的透传生产适配器。

Assistant 的领域问题摘要保留最多 8 项边界，按路径稳定排序，输出 problems/total/omitted；这仅计数领域问题，不报告队列或工程诊断，空摘要仍为 unknown。

本次分类与调用方选择修复已完成；统一完整读取、Assistant 来源绑定、旧接口清理、字段与嵌套属性隔离回归、完整检查及四个模拟器构建均通过。具体结果与未执行的模型/设备验收见验证记录的 2026-10-31 章节。

## Recursive State contract audit — 2026-10-31

Audit direct reads as well as root-composed trees. Findings to correct before claiming uniform coverage:

- Storage CacheContainer/FilesContainer return unclassified, non-Codable statistics; only StorageContainer wraps them. Move StorageStateSnapshot to existing Support/Contracts (StorageCore), return that exact schema directly from Cache/Files/DatabaseStorage, and compose those child results unchanged. Keep BufferCache's low-level locked statistics distinct from the container contract. No new directory or cross-module dependency.
- UI diagnostic test lifecycle, support/capture/fallback/sample-rate configuration belongs to Runtime. Business retains actual input route, permission, signal/level and measured direction. State strings must use finite declared raw values, with field meanings/units/value sets. Diagnostic task execution is not ordinary user speaking/listening.
- Motor lastResult currently mixes physical/business outcomes and internal failure codes. Keep stable business outcomes (arrived/notReached/timedOut/cancelled/unconfirmed), preserve the original technical failure under Runtime and document unconfirmed effects. Do not change execution/cancellation/safety behavior.
- Native connectivity must not infer feedback loss from a technical quarantine or generic health level. Report position-feedback unavailability only from connected-session measurement evidence; preserve transport/watchdog/quarantine separately in Runtime/health. Native issue wording must remain SDK-level.
- Replace debug String(describing:) serialization in State fields with explicit raw-value enums. Clarify Settings cloud intent and operation/camera/album semantics through meanings rather than inference from generic field names.
- Strengthen internal inspection validation and tests: consistent JSON schema for seven module types and all direct child reads; disjoint Business/Runtime keys; valid metadata references and enum values; direct Storage child/tree equivalence; diagnostics classification; motor business-result versus technical-failure separation; passive unknown and no filesystem/device effects. Preserve Assistant-owned selection and Skill useStates.

After implementation, reconcile each owning README, Storage compilation ownership/Package/Xcode references, architecture checker and validation evidence. Run check.sh and all four iOS Simulator builds. Report dynamic nodes as conditional owner scopes rather than inventing devices or facts.

Additional data integrity finding: UInt64 revisions/counters are converted to Double and lose precision. Add the same exact unsigned-integer Value representation to all seven local schemas and App structural view, and use it for UInt64 observations. Runtime inspection rejects category overlap and invalid metadata references rather than accepting ambiguous nodes.

Health audit clarification: a UI form/album operation error is a Business outcome, not proof that its presentation container is unhealthy. Keep typed operation problems/content failure in Business and leave UI engineering health unknown absent actual presentation-health evidence; preserve raw error text only in its UI owner.

Native source classification is also closed and explicit: each PlatformStateSource declares Business/Runtime field sets as schema data. Platform root retains every declared field and rejects added/unclassified native keys; native schema growth must not silently classify future technical fields as Business. Use the common typed Value decoder instead of NSNumber/debug conversion.

Audio observation validity: retain display observations without mutating refresh/expiry, but publish sample age plus signal/direction freshness as Business evidence. Missing receipt/deadline stays unknown, expired values stay explicitly historical; sample rate/capture machinery remains Runtime.

Model artifact failure counts remain Runtime evidence of retained operation results; they must not synthesize current component-health degradation. Preserve explicit root/backend lifecycle failures separately.

本次递归契约审计已完成：32 个具体 Container 及公开反射子节点的结构、分类、枚举、精确计数与元数据已核对；直接 Storage 子读取与根树保持同一契约。完整检查与四个模拟器构建通过；模块分类清单、动态范围及未执行验收见验证记录的 Recursive contract audit 章节。

## Single-node reads and exact Skill paths — 2026-10-31

Supersedes recursive Container snapshots and alias/summary model sources. Every concrete Container and published node reads through stateSnapshot() async throws and returns only its own classified data. children is a Codable array of path-only Reference values; Descriptor.children uses the same references. Remove Container-level stateDescriptor wrappers; obtain snapshot.stateDescriptor from the already sampled value. No read traverses or aggregates descendants implicitly.

Each module root supplies stateReaders() async throws: a bounded metadata catalog of exact paths and weak-owner read capabilities. Enumerating this catalog may inspect existing owner identities/registrations but must never call stateSnapshot, sample unrelated state, prepare models, create a camera/driver or execute work. Module-local Snapshot.Reader types preserve foundation independence; App erases only structure. App registerRoot binds a catalog factory, snapshot(path:) resolves exactly one capability and samples only it. An explicitly named inspectTree(path:depth:) is caller-owned diagnostics traversal with separate tree data; recursion is never part of the node snapshot or Assistant's source read. Preserve bounds, cancellation, partial read failure, owner lifetime and reflection validation.

UI roots/home/diagnostics separate expression/audio logical readers; Storage and Agents roots return child indices without sampling children. Gateway retains existing configured facilities and exposes independent readers. Platform root, system group, eight native sources, connectivity, link and each axis have separate readers. Model root/capability nodes only enumerate resource IDs; registered resource nodes sample one selected resource. Actions root uses already-owned business readers; robot/motion/axis have independent reads. Root robot does not sample motion: targets move to explicitly selected actions.robot.motion; tracking goals owned by the service remain local. No business execution, scheduling, lifecycle, native control, safety or persistence policy changes.

Assistant ReadState requires a nonoptional exact path and consumes a single node. Remove system.health/system.diagnostics tree scans; internal diagnostics remain explicit caller operations. Canonicalize agents.applicationcontrol, ui.home.expression and platform.system.* in Skills, bindings, fixtures, tests and docs. RobotInteraction explicitly declares actions.robot.motion. Loading a does not load a.b or a.b.c; a.b.c can be selected directly without selecting ancestors. Child indices and metadata do not become LLM state facts automatically. Keep business field selection Assistant-owned. Update the four affected Skill revisions/teaching without increasing prompt budgets or changing action authorization.

Affected files: all seven Snapshot contracts and Container readers, owning logical-node readers, App ApplicationStateInspection/ServiceFactories, ModelManager metadata/resource reads, ActionsBusinessAssembly, AssistantStateBindings/AgentContainer, Skill definitions/teaching, architecture audit, integration fixtures/tests, overall and owner READMEs. No new directory, dependency or common cross-module protocol.

Validation: parent read causes zero child reads; path lookup causes zero ancestor/unselected reads; Reference encodes indices only; exact Skill union/release and independently selected descendants; cancellation/bounds/closed scope/missing node; previous Business/Runtime invariants, primitive codecs, device behavior, application/Skill prompt regression. Run focused tests, check.sh and all four build-ios.sh schemes. Automated/Simulator validation does not replace real-model or physical-device acceptance.

本次单节点整理已完成：所有 Container 方法统一 async throws，children/Descriptor.children 只返回路径索引，节点定位不采样祖先，显式诊断遍历与 Assistant 精确 Skill 声明分离。关联源码、夹具、教学和技术 README 已同步。完整检查 910/225 集成用例与四个模拟器构建通过；独立实机/模型验收未执行，见验证记录最后章节。

## Container-owned State collection lifecycle — 2026-10-31

State follows its existing Container/authoritative domain owner's lifetime. Construction establishes unknown external facts; start installs passive observation before seeding real native values. Subscription updates replace bounded latest values. Foreground resume reconciles missed changes. Invalidation fences callbacks before cancellation; stop joins owned observation work. Snapshot/catalog/Skill loading never query native sources, refresh caches, start hardware or request permission. Existing actor-owned software facts remain authoritative in memory; do not introduce a duplicate global mirror.

Implementation steps and ownership:

1. Platform Core: introduce bounded, module-private resident source collection in existing Core files. Seed synchronous OS sources at root start; source failures stay explicit. Subscribe to OS changes before the seed, refresh time from an owned one-second clock event, and refresh permissions after permission operations/foreground reconciliation. Selected native State reads and Audio/Vision/Connectivity authorization reflection use stored values only. Network keeps its existing generation-fenced latest-value owner; first real path observation is distinct from an unknown initial value. Track collection phase in Runtime rather than inventing a Business fact. Preserve current synchronous start admission API; asynchronous native sources explicitly report awaitingFirstObservation until their first actual event, rather than falsely claiming complete hardware initialization.
2. Connectivity: expose the native link's resident observation reference, updated at the same native publish point as its existing business stream. Inspection reads that memory without consuming the existing single-consumer stream, initializing a driver, or calling a raw status getter. Unsupported injected links retain unknown State. Connection positions are unknown until an actual connected-session receipt. No active feedback command or scan is introduced by reflection.
3. Camera: retain actual running observations during the existing owner initialization/event/operation lifecycle; State serialization uses that resident value. Initialization and native events reconcile real status; start/stop/switch completion update it before reporting completion. A State read must not call camera.isRunning(). Keep capture admission and physical cleanup checks intact.
4. Audit remaining modules: UI, Agents, Gateway, ModelKit and Storage project their existing in-memory authoritative state, without new parallel caches. Retain pure age/freshness derivation from recorded receipts and injected clocks; it performs no native query. Exact node boundaries, Business/Runtime classification, Skill useStates and Assistant selection remain unchanged.

Affected designs/files: PlatformContainer, Core/NativeSystemState, Audio/Vision/Connectivity containers, native permission operations, NexArmBluetooth publish/observation contract, CameraCoordinator; overall and owning READMEs; PlatformState/NexArm/camera regression tests and validation records. No new directories, modules, dependencies or generic cross-module collector.

Validation: startup seed before first read; subscription updates without intervening reads; reads do not invoke injected raw samplers; cold/stopped and first-event unknown; source failure propagation; old-generation rejection; clock/foreground reconciliation; shared BLE memory does not steal business events; camera State does not query hardware. Then scripts/check.sh and all build-ios.sh schemes. Stub/Simulator evidence remains separate from native UI, real-model and physical-device acceptance.

Audit refinement before Agent edits: AgentContextRepository.snapshot() lazily restores/commits persisted context. Role Container reflection currently calls that path, so an installed-but-not-started role can perform storage I/O during State reads. Add a residentSnapshot accessor returning only the last initialized committed memory (nil before initialization), forward through each owning Agent's residentContext accessor, and use that in role State serialization. Existing start() already performs restore; preserve all operational contextSnapshot/transaction contracts. Cover no-load reads and unchanged startup restore in repository tests; update Agents/Context/role design descriptions. Remove replaced BLE observedStatus reflection API after moving its final caller/tests to the resident reference; retain operational status semantics.

本轮生命周期实现与自动化验证已完成：原生同步来源在启动时采集并保存，异步反馈明确等待真实观测；订阅、时钟、恢复重同步、停止围栏/加入、机械臂常驻状态引用、相机运行事实及 Agent 私有内存读取均已对齐。软件已有权威状态不另建镜像；Skill 的精确渐进披露与调用方分类选择保持不变。最终完整检查 919/225 集成用例及四个模拟器构建通过；首次测试时钟依赖问题已隔离并复验。具体证据与未执行的真机/模型验收见验证记录 Container-owned State collection lifecycle 章节。

## Producer/consumer decoupling re-audit — 2026-10-31

Recheck all concrete Containers, logical/dynamic reflection nodes, collectors, catalogs, App structural inspection, Assistant bindings and Skill selection. Decoupling means producers publish complete domain-owned classified facts with no caller/Skill/LLM policy or read-triggered work. Consumers depend on the stable State schema and choose their own fields. Existing typed commands, receipts, streaming observations and effect-time safety validation remain domain interfaces; they must not be replaced by untyped reflection dictionaries.

Findings and intended fixes, before code edits:

- ModelScope exposes preferCustomRecognition/preferCustomSynthesis in Business although SpeechSelection uses them as backend-routing configuration. Move both fields unchanged to Runtime, preserve configuration and provider selection. Keep UI-owned editable settings drafts distinct from model execution configuration. Update ModelKit/Management design and classification regression.
- Storage root synthesizes Business.problem directly from its lifecycle failure. Remove this engineering-to-Business convenience projection; retain runtime lifecycle, health and issues/impact. Record/operation domain failures retain their original typed contracts. Update Storage design and test failed-start reflection.
- Platform permission child adapters swallow cached-source/decoding failures as unknown while the source node throws. Make module-private permission read closures/accessors throwing; cold/suspended/released ownership remains unknown, but admitted sampling/schema failures propagate consistently through Audio/Vision/Connectivity snapshot reads. Do not add caller-specific filtering or native queries. Update Platform and child READMEs plus failure regression.
- Audio scope owner State uses String(describing:), an unstable debug encoding. Use a finite raw-value Scope enum and descriptor vocabulary under Runtime. Keep the same scope identity/admission behavior.

Also verify metadata/cancellation at exact motor reads and retain all existing single-node/Skill/privacy bounds. Tests must distinguish configuration from domain state, lifecycle fault from Business outcome, cache-unavailable unknown from actual cache-read error, and producer output from Assistant selection. Run focused tests, scripts/check.sh and all scripts/build-ios.sh schemes; publish an explicit seven-module inventory and any remaining limits in docs/validation. No new directories, modules or dependencies.

Re-audit refinement before UI/Assistant edits: ui.navigation.operation is a stale reflection field from the removed album aggregation. NavigationState has no owned operation value; contextSnapshot() without album always supplies nil. Remove the redundant field from the navigation State projection and its Assistant field selection. Preserve NavigationState.contextSnapshot(album:) for actual UI composition and ui.album.operation as the independently selected authoritative State. Do not change Skill paths, page operation execution, navigation confirmation or album behavior. Extend the existing local-navigation regression and reconcile UI/Assistant READMEs. Final checks/builds must include this cleanup.

本轮生产/消费解耦复查完成：32 个具体 Container 与公开逻辑/后端/动态节点已逐项核对；修正语音后端偏好分类、Storage 生命周期故障摘要、权限读取错误吞没、Audio 作用域调试编码，以及导航遗留的相册 operation 字段/消费映射。已补分类、故障、枚举、生产端不受 Assistant 选择影响和本节点归属回归；最终完整检查 923/225 集成用例及四个模拟器构建通过。源状态语义仍归领域所有者，消费策略留在调用方；类型化操作和效果时安全校验保持原职责。完整清单、证据与未执行设备/模型验收见验证记录 Producer/consumer decoupling re-audit 章节。
