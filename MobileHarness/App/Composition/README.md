# Application composition

## Ownership and files

`ApplicationLanguageSettings` keeps the application preference and resolved locale outside replaceable service roots. `ServiceFactories` binds a thread-safe snapshot reader to Agent requests and provides the corresponding Apple recognition locale to the ModelKit root.

This directory constructs and connects public module interfaces, installs static lifecycle services and composes UI presentation. It contains no business request consumer, per-frame forwarding, function registration, role policy or domain schema conversion.

| File | Responsibility |
| --- | --- |
| ApplicationContainer | FactoryKit instance cache for seven roots, root capability aliases and the failure channel; compiled as AppStorage. |
| ServiceFactories | Scoped backend selection, deferred repositories, module roots and thin public capability adapters. |
| ApplicationActionAssembly | Supplies Actions dependencies and adapts public cognitive/execution ports. |
| ActionServiceAdapters | Narrow camera/device/voice/detection and resource-run adapters; no business service registry. |
| ModuleRegistration | Public lifecycle bindings and explicit startup/rollback/stop graph. |
| MemoryPressureRelay | Owns the single subscription to the PlatformKit memory-warning listener and calls ModelContainer.handleMemoryPressure once per delivered warning; compiled as AppStorage so it is testable. |
| AppComposition | Services lifetime, bootstrap, retry and scope replacement. |
| ApplicationPresentation | UI application/session interfaces, existing role state/control and navigation/preparation callbacks. |

Foundation aliases refer to the same owning roots. Services retains ActionsContainer, GatewayContainer and AgentContainer independently. ActionsBusinessAssembly is an Actions-owned helper retained/cleaned by ActionsContainer, not another lifecycle root. Domain/module/action declarations remain extensible library values.

## Wiring and order

```mermaid
flowchart LR
    subgraph Foundation["FOUNDATIONS READY"]
        S["storage"] --> M["model"]
        P["platform"]
        U["ui"]
    end
    S --> B["executionBindings"]
    M --> B
    P --> B
    U --> B
    B ==> X["actions"] ==> G["gateway"] ==> A["agents"] --> H["homePreparation"]
    M --> R["memoryPressure"]
    P --> R
    classDef host fill:#eaf2ff,stroke:#5078b8,color:#203b64
    classDef action fill:#ffecef,stroke:#b86178,color:#6b2b3d
    classDef gateway fill:#fff2d9,stroke:#bf842c,color:#694511
    classDef agent fill:#f0eaff,stroke:#8261b5,color:#463065
    class B,H host
    class X action
    class G gateway
    class A agent
    style Foundation fill:#f5f9f8,stroke:#8ca89f
```

Diagnostics precedes foundations. Thin arrows are readiness dependencies and thick arrows emphasize the business-root readiness chain. This graph describes lifecycle, not imports. After foundations start, executionBindings connects the cognitive request to Actions-owned service assembly, configures Gateway with the neutral execution port/resources/result callback, validates immutable catalog coverage and binds hosts. Configuration does not open business admission or devices.

Stop reverses dependencies and retains ports through Agent, Gateway and Actions cleanup. Binding rollback also stops a cold/configured Actions root if startup never reached its own node; an already stopped root is not stopped again. Every root owns and joins its own tasks; App does not inspect another module's worker registry.

## Foreground, replacement and errors

Initial startup requires an active Scene. Once running, model/platform/UI/Actions/Gateway/Agents declare background continuity: scene loss keeps voice, inference and accepted business work alive while UI detaches local surfaces and Actions/Agents stop camera, tracking and foreground device work. Actions resumes scene admission separately from its owned artifact preview restoration. Window recovery diagnostics belong to Actions rather than the root preparation state. Full invalidation remains reserved for startup rollback, replacement and root shutdown. A successfully rolled-back startup interrupted by system inactivity waits for active before replacing its scope. One replacement task coalesces events; cleanup failure retains the old scope/error and prevents duplicate native owners.

Background URLSession completion can use the same model/storage scope before foreground startup. Replacement joins those roots even if they never reached the graph's started set. No camera/audio/UI inference is started by background restoration.

ApplicationContainer projects each module's structured Failure, including ActionsFailure and GatewayFailure, into the existing diagnostic channel while preserving original errors. ModuleRegistration normalizes only pure cancellation after recording evidence; mixed cleanup errors remain failures. App supplies bootstrap failure before roles can present diagnostics. App binds the main Actions Shell scheduler to [RuntimeLog](../../UI/Components/RuntimeLog/README.md) with a newest-one snapshot buffer and joins that consumer when execution bindings stop.

ForegroundPreparation runs behind the foreground and visible-home barriers. ApplicationActionAssembly resolves named ModelKit handles from the confirmed selections and forwards real preparation activity to the home projection and Agents. See [Lifecycle](../Lifecycle/README.md) and [overall flows](../../README.md).

## Native State capability binding

ServiceFactories injects the complete ApplicationStateInspection.snapshot read into AgentContainer. Native facts retain PlatformContainer ownership; Assistant projects their complete Business dictionaries. This binding adds no App sampler, JSON schema conversion or extra lifecycle node. Platform startup owns passive native observation; Agents selects per-request reads, and roots retain their existing reverse cleanup order. Neither Actions nor Gateway is an intermediary for native State reads.

## Observation and query composition

App binds complete inspection.snapshot(path:) reads and reports scene/model preparation to Agents. Skill owns exact-path selection; Assistant projects Business; App does not convert or filter domain schemas. Navigation State includes UI-owned page and album context. Specific business query Actions retain their owning services; App binds no generic environment/last-result callback from Agents into Actions.

## Internal state inspection

`ApplicationStateInspection` registers seven scoped module catalog factories, each returning exact paths and read-only reader capabilities for existing owners. Factories contain no state copies, filtering policy or service creation. Module-local data is structurally encoded/decoded only in this adapter; independent foundations do not import a shared State module.

`snapshot(path:)` resolves and reads exactly one node, without reading ancestors or siblings. `describe(path:)` derives that node's descriptor; callers with a snapshot use its stateDescriptor directly. Local snapshots contain child Reference indices only. Registration/lookup bounds catalogs to 256 nodes and encoded samples to 256 KiB. Category overlap, invalid child indices/metadata/enums, malformed paths and cancellation propagate. Owner read/encoding failure is readFailure with unknown health; a rejected configuration fences reads. The registry and State contain no global atomicity claim.

`inspectTree(path:depth:)` is explicit internal caller orchestration: read a node, follow its indices within depth 16 / 256 nodes / 256 KiB, and materialize a separate Tree. Trees preserve each owner’s health without ranking or aggregating it. Tree traversal is not an Assistant source or model tool.

App binds only exact snapshot(path:) into Agents. Assistant projects complete Business for Skill-declared paths through a unified resolver. No alias or system.health/system.diagnostics scan can reveal an undeclared descendant. The weak Agent catalog binding avoids retaining the Agent root through its injected read callback. Lifetime, execution, UI and device behavior remain owned by their existing modules.

App explicitly sequences execution preparation: AgentContainer prepares cognitive inputs; ActionsContainer.configureBusiness owns business assembly preparation and returns execution/catalog/host ports; the Agent preparation validates Skill coverage and returns Gateway configuration; App configures Gateway and calls AgentContainer.bindExecution with the resulting facilities. The executionBindings lifecycle node retains this configuration boundary for partial-start rollback and reverse cleanup. Actions owns internal function binding; App owns the cross-module sequence.

ModuleRegistration configures GatewayContainer for transport and passes those ports and the Actions host to AgentGatewayAssembly. Composition registers the Actions request endpoint and the Agents result endpoint on the same transport. The Actions host owns request interpretation and execution. The Agents adapter owns interpretation and local role delivery of terminal results and execution events. AppComposition forwards home visibility to ActionsContainer separately from scene lifecycle. Actions combines visibility with scene admission. Agents stops its own roles/perception, Gateway drains transport, and Actions joins execution and native cleanup.

ServiceFactories supplies ActionsDependencies through the App callback bridge, asks ActionsContainer.makeBusiness for the root and host capabilities, and registers that same root in ApplicationContainer. AppCameraAccess/AppDeviceAccess adapt Actions-owned public protocols to Agent-owned protocols; they never retain the private assembly or concrete execution workflows. Runtime configuration calls ActionsContainer.configureBusiness(request:) after foundations start.

ApplicationPresentation requires bootstrap and delegates complete session availability to SpeechPerception.presentation. The Actions Shell owns runInCurrentContext, coordinated acquire and isSettled; the resource adapter contains only forwarding and boundary error conversion. Foreground model requirements come from Agents and preparation steps come from ModelKit. ServiceFactories maps those generic steps into the App-owned lifecycle coordinator without inspecting ModelState or selecting model providers.

ApplicationContainer caches the root window capability; AgentContainer and ApplicationPresentation receive that same WindowState. The root attaches WindowHost above persistent navigation. Navigation visibility gates home model preparation. Actions handles camera scene and window lifecycle.

ApplicationPresentation.cameraPreview builds the photo renderer with showsPose=false. The root retains the separate Face background visual renderer, shares the same native camera injection, and uses actual native image aspect to update the camera window sizing policy. Composition creates no second capture session.

组合注入同一个UIContainer.island到AgentContainer与ApplicationPresentation；根页面挂载前台IslandHost，系统岛点击只恢复既有场景，Actions业务装配拥有活动适配。App只传递基础呈现端口，不计算活动优先级或控制相机。

IslandState自身管理ActivityKit摘要和SwiftUI本地呈现，组合层不创建第二个系统活动owner。系统链接不改变导航/窗口/展开偏好；后台仅拆本地呈现，系统摘要随真实会话继续。根停止加入清理，进程终止的尽力清理端口属于UI，App delegate只转发。

ApplicationContainer injects IslandDeviceStatusReading into UI construction. Its closure structurally maps PlatformContainer.systemStatus() typed power/network fields into UI-owned values. It owns no polling, native sampler or presentation rule; the visible Island component controls cached-read lifetime and layout.

Web presentation is injected directly from UIContainer into ApplicationPresentation/ApplicationRootProviding. ApplicationContainer configures the separate WebWorkspaces filesystem location. ActionsBusinessAssembly owns browser, deterministic artifact storage/presentation and screenshot services; Writer owns model editing; App adds no editing logic or worker.

ApplicationPresentation 将 WriterContainer 的 WriterRecordsControlling 与 Actions 的 WriterArtifactsControlling 注入 Writer 专属任务页面；不再为 Writer 组装 Assistant 会话历史管理或标题工作流。任务、消息、图片读取由 WriterContainer 提供；文件预览与导出由 Actions 根管理。

Settings uses independent assistantHistory/writerHistory routes to injected My Assistant/My Writer record destinations. Writer request summaries are projected by WriterContainer; App does not parse SQL, model calls or progress policy.

普通Scene转发保持Writer创作连续，仅通知其预览可见性；Actions在前台恢复Artifacts最新快照，UI继续独立管理原生表面可用性。显式根暂停/替换/关闭沿原清理图执行，不借用Scene事件暂停Writer模型循环。

AppComposition 持有一个 WriterContinuedProcessing 适配器，向每个根的 WriterContainer 注入执行端口。根替换先加入旧 Writer 清理，再绑定新根。系统任务回调经执行段身份返回 Writer，系统适配器只管理 iOS 执行时间与进度。

ActionsDependencies receives a lazy WorkspaceRepository getter from the existing Storage database, alongside media/device getters. It is resolved after foundation readiness and creates no parallel database or JSON catalog.

ApplicationActionAssembly 将 AgentVoiceHost 的播放登记与播放变化回调透传到 ActionsVoiceHost。Assistant的语音子能力接收真实播放事实并决定展示；App只连接接口，Actions不导入Agents，基础UI不接收业务接口。播放频谱仍直连UI的专用数据接口。

Composition passes the root Storage cache to Actions and adapts scoped previewSnapshot/resetPreviewSelection through neutral host ports. It does not prepare images or own selections. Agents registers actions.camera.preview against the same Camera owner used by UI capture.

ApplicationActionAssembly 不再向 Actions 注入 Memory 的历史执行预览函数；Assistant 详情直接消费既有 History 读取接口及已记录业务快照。

ApplicationActionAssembly 传递 Decision 配置读取、分类状态与队列投影闭包。配置快照包含本地模式和可选云端工厂，由 Actions 提供。业务分类在 Agents，原生模型在 ModelKit。

Assistant 会话使用角色自身的 UI.Island 权限发布 Decision 反馈。App 继续装配通用 Gateway 与 UI 渲染端口。

ApplicationActionAssembly 将 ActionsBusinessBindings.readWebScreenshot 直接透传给 AgentBusinessBindings。Actions.Web 拥有当前截图，AgentRuntime 注册 actions.web.screenshot，App 不存储、压缩或解读图片；原 Camera readPhoto 网页桥接已删除。

ApplicationActionAssembly receives the existing selected-language reader from ServiceFactories and passes its current value into ActionActivityItem projection for each execution snapshot. The language preference remains App-owned; projection does not rewrite canonical identities, business return values or producer diagnostic evidence.

ApplicationActionAssembly forwards the Actions-owned speech-detection preference reader to AgentBusinessBindings unchanged. Agents snapshots the returned window count and probability when creating its VAD session; App neither stores nor interprets those settings.

ApplicationActionAssembly collects configured Assistant, Writer, Decision, speech and enabled vision resources, then deduplicates by resolved ID. Zipformer, Smart Turn and DeepFilterNet3 use this preparation path when selected. A cloud handle prepares the client configuration. The home projection carries the actual resource name for the loading Toast.

Settings owners report affected roles and incoming model IDs before persisting. App closes home preparation, cancels dependent work through AgentContainer, and unloads affected resources through ModelKit. The home worker reads the committed settings before preparing a new generation. Active role admissions reopen after readiness. Effective locale changes enter the same barrier, coalesce to the newest locale, and cover recognition, synthesis and language-sensitive agent prompts. See [model lifecycle](../../ModelKit/README.md#managed-model-resources).

语音宿主桥透传 `preparePlayback(audioID)` 的句柄登记和 `playbackChanged(audioID, active, time)` 的逻辑播放生命周期。Agents 选定档位后通过 Gateway 发送独立音量 Action 或向当前 `speak` 实例发送生命周期命令。Actions 拥有播报控制器和原生状态确认。

ModelContainer 自行构造模型文件与下载能力；ApplicationContainer 不计算模型路径、不注入 Storage 文件接口。模型生命周期只依赖 diagnostics。下载偏好只从 Settings/download-source.json 读取，不搬迁旧位置的文件。

ServiceFactories.make 接收可选存储根，默认仍为 App Application Support。AppComposition 接收构造服务的闭包与语言偏好对象，首次启动及替换复用同一工厂，ModuleRegistration 图保持唯一；stop 加入正在进行的替换后关闭当前根。隔离 Simulator 验收使用这些接口覆盖实际生产装配，测试不提供另一份生命周期图。

Composition injects module-owned external listener ports without introducing a shared foundation dependency: PlatformKit supplies media/native state, UI supplies requests/presentation facts, and ModelKit supplies artifact revisions. The responsible role or execution service owns the consumer task and cancellation/join. Gateway is the internal Request/Reply and event transport root. Endpoint owners supply handler catalogs and own execution.

ModelKit 的前台生命周期独立预热已安装的 Zipformer，并监听安装状态。可选预热不加入 Home
就绪条件。App 将 Actions 的快速打断偏好读取端口绑定至 Agents。新采集读取该选项；
默认在全双工回复中观察符合门限的命中。

语音设置把按能力保存的模型 ID 与可选合成音色交给 ModelKit 应用；App 在切换期间复用现有语音
维护边界。前台准备继续分别调用识别、合成和 VAD 的中立接口。已安装的可选降噪
与关键词模型仍使用各自的预热入口。
