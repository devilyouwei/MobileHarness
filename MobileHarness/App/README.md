# App — Application host and composition root

## Responsibilities and direct interfaces

App creates and retains the unique scoped roots, injects narrow public interfaces, connects scene/system callbacks, and governs startup, foreground transitions, joined shutdown, rollback and replacement. It does not interpret business intent, consume business requests, encode Signals or register individual functions.

| Neighbor | Public relationship |
| --- | --- |
| iOS / Scene | Activity changes and background URLSession callbacks. |
| Storage, ModelKit, PlatformKit, UI | One root per scope; aliases reference owning root capabilities. |
| Actions | One ActionsContainer with public host capabilities and execution/catalog ports; its business assembly is private. |
| Gateway | One GatewayContainer configured with neutral execution, resource mechanisms and result delivery. |
| Agents | One AgentContainer receiving Gateway ports, immutable metadata and neutral host collaboration ports. |
| AppLifecycle | Generic ManagedService graph, preparation, rollback and foreground barriers. |

## Internal structure

[Composition](Composition/README.md) owns registration, factories, public adapters and lifecycle installation. [Lifecycle](Lifecycle/README.md) owns the generic graph and preparation/system callback mechanisms. MobileHarnessApp mounts UI.ApplicationRootView and forwards Scene state. ApplicationPresentation composes existing UI/role interfaces; pages do not own module work.

ServiceFactories creates roots and thin adapters. Actions constructs domain services and business functions; Agents constructs cognitive roles and policy. App injects Task control/perception/resource interfaces without decoding business schemas or interpreting resource ownership. Domains, modules and functions have no App registrations or peer containers.

## Lifecycle and failure

Construction is inert. Startup orders diagnostics → storage → model → platform → ui → executionBindings → actions → gateway → agents → homePreparation. The foundation readiness edges do not create foundation compile dependencies. executionBindings prepares metadata/services, validates Skill coverage and installs host ports before business admission; it does not operate devices.

Shutdown reverses that order. Agents closes requests and joins roles; Gateway joins scheduling, execution, transport and delivery while Actions remains available for cleanup; Actions joins native/business work; executionBindings finally unbinds. Startup failure rolls back the current node and completed stages while preserving original and cleanup failures. A failed cleanup prevents replacement.

Initial inactive waits for active. Synchronous invalidation closes admission before asynchronous pause. Rapid reactivation completes necessary suspension first. One replacement task coalesces retries and rechecks foreground state; there is no replay queue. Durable records/media remain independent from runtime work.

ForegroundPreparation is root-owned and active only for visible foreground home. It uses public readiness/preparation interfaces, independently of ordinary conversation waiting. Background artifact restoration may use the same model/storage roots before foreground startup; replacement still joins those owners. Native UI, real-model and physical-device evidence remains separate in [validation](../../docs/validation/README.md).

## System facts and context injection

App binds the existing complete classified State inspection read into Agents. It does not mirror native facts or generate model context. Passive native observation follows Platform lifecycle; Agents requests selected snapshots while its own request admission is live. See [composition](Composition/README.md#native-state-capability-binding) and the [overall State path](../README.md#container-state-read-path).

Application observations flow to the Agents-owned summary source; App does not bind a generic environment-query callback into Actions. Navigation is read from its existing UI State owner. See [composition](Composition/README.md#observation-and-query-composition).

## Reflexive composition

App binds the seven already-owned module state ports into the exact-path ApplicationStateInspection reader registry. Generic structural encoding stays in that composition adapter; modules own domain fields and state transitions. Agents receives the complete unfiltered inspection read. Skill useStates alone selects exact nodes; Assistant projects the producer-owned complete Business dictionary. Other internal consumers choose independently. No tree tool, background sampler or automatic repair is added. See [Composition](Composition/README.md#internal-state-inspection).

Container snapshots are local; App exact-path resolution does not sample ancestors. Full diagnostic traversal is an explicit inspectTree operation, not the read callback injected into Assistant.

App explicitly sequences execution preparation: AgentContainer prepares cognitive inputs; ActionsContainer.configureBusiness owns business assembly preparation and returns execution/catalog/host ports; the Agent preparation validates Skill coverage and returns Gateway configuration; App configures Gateway and calls AgentContainer.bindExecution with the resulting facilities. The executionBindings lifecycle node retains this configuration boundary for partial-start rollback and reverse cleanup. Actions owns internal function binding; App owns the cross-module sequence.

App directly configures GatewayContainer using Agent-prepared neutral configuration, then supplies public Gateway capabilities back to Agents. Home visibility is forwarded to Actions independently of scene lifecycle. Actions owns camera/device scene cleanup; Agents owns role/perception cleanup.

App injects foundation capabilities and deferred repositories through ActionsDependencies. ActionsContainer.makeBusiness returns a scoped root and public camera/device/UI host capabilities; ApplicationContainer caches that root. Business service construction and cleanup remain within Actions.

## Responsibility boundaries

ApplicationPresentation.prepare requires AppComposition bootstrap; it never starts a module independently. SpeechPerception publishes a complete session presentation capability with stable identity; App adapts it to UI interfaces without reconstructing readiness from optional fields.

Agents declares foreground model requirements. ModelKit returns preparation steps with native readiness and warmup semantics. App owns only activation by scene/home visibility, interaction gating, the generic preparation worker and structural UI-state adaptation. Resource context resolution, lease lookup, coordinated acquisition and settlement interpretation are Gateway operations; App adapters forward those operations across public protocols. Model error publication classification belongs to Agents' failure channel, while App injects error sinks and structurally projects module errors.

ApplicationStateInspection supports exact reads, descriptors and explicit bounded trees. It contains no health ranking, diagnostic allowlist or historical-failure projection. The failure journal remains with its existing owner.

前台及系统灵动岛由UI基础模块拥有；App复用同一根IslandState并转发生命周期。系统岛链接固定mobileharness://island，激活既有场景，保留离开前的导航和窗口；冷启动遵循正常首页流程。UI根不分发旧岛链接到记录/相机/蓝牙。原生终止回调仅调用UI拥有的有界ActivityKit清理端口，不保证强杀回调。主App与Simulator目标均嵌入MobileHarnessLiveActivity扩展；Widget只编译UI中立摘要及Widget入口，不接入App业务装配。

已启动图通过continuesInBackground声明后台连续性，首次启动/替换/根停止仍执行完整失效。Scene不可见仅停止视觉与前台设备服务，保留已开启的语音会话、执行链和同源Live Activity。实现及约束见Composition与Lifecycle；不创建后台轮询/静音播放保活。
