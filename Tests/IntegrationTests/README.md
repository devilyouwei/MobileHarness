# IntegrationTests

WriterHistory 集成回归覆盖本轮 user/tool 输入快照和工具目录的 SQLite 重开、输入独立 checkpoint、日志清除后保留与 UI DTO 投影；任务摘要检查开始时间、更新时间及轮数，内部执行状态仍独立验证。

## 职责与构造边界

通过真实 Agent/Gateway/Action/Tool/Storage 接口和注入模型、设备及呈现端点验证跨模块契约。ActionCatalogFixture 在每个作用域安装相同不可变生产声明；并发、失败与完成使用显式 gate/反馈同步。常规用例不推理真实模型、不控制硬件；真实 provider 和串口验收必须单独启用。

`DecisionLanguageEvaluationTests` runs the current Assistant Decision renderer and disposition policy with the real local D3 model. The [experiment runner](../../scripts/evaluate-decision-language.sh) enables it explicitly and writes a JSON report. Speech transcripts and playback states are fixtures.

## 当前覆盖

BasicSkill 控制教学回归检查九个已注册别名均有独立效果说明，打包指令包含 Skill/Task/State 的区分与跨请求生效规则。已有 AgentTaskSkillTests 验证 Task 持有项的显式释放仍保留活动目标、非法释放原子拒绝、初始 Skill 接管及终态清理；资源教学不引入具体业务例子或业务 Skill ID。

PromptTemplateTests 动态枚举 Catalog 中所有非基础 Skill，验证默认请求可发现它们，但其私有指令/函数未加载；解析测试侧 loadSkills 调用、提交真实 Skill 状态后，下一请求获得对应教学/函数，旧目录仍拒绝新增函数。BasicSkill 的通用教学不包含这些业务 Skill ID。QwenWorkflowEvaluationTests 为 browse 返回明确标注的合成文本或失败；不打开网站、不生成截图，模型决策结果不能当作真实网页访问验收。

PromptTemplateTests 验证摄影完成示例先单独解析为 Camera.Capture.close，下一示例才允许 Agent.Task.finishTask；装配提示保留关闭失败、独立视觉及重拍分支。此处验证资源和解析契约，不代表真实模型会遵循收尾流程。

SpeechPlaybackTests 通过真实 AudioCache／SpeechPlayback 与显式退出 gate 验证 VoiceReplyCancellation；播放取消加入前、原生停止加入前均保留未播放句柄，最后会话清理无 missingAudio 故障；中断正常返回、失败或取消时均完成清理并保留原错误。PCM／原生停止为替身，不宣称真机或真实合成验收。

PromptTemplateTests 通过生产目录和增量解析器读取 ExpressionInteraction 的子集串行/全量语音并行示例，核对每个 wait 的表情、默认 Channel、语音对应关系及全量示例对所有合法 express 值的覆盖，并检查默认请求包含教学。现有调度器 wait 回归验证组内跨 Channel 并行和组间完成屏障；合成测试不代表 Flash 真实模型遵循验收。

| 文件/用例组 | 主要边界 |
| --- | --- |
| AgentTaskSkillTests | 基础/近期/Task Skill 所有权、五次完整 Decision 闲置回收、使用续期、Task 接管及终态、等待/替换、依赖预算、在途保护、LRU、会话/重启与原子提交 |
| AssistantChatTests / GenerationRoundTests | 多轮上下文、原生配对、Action/Tool/混合屏障、第二输入优先、真实业务输出与完成证据、拒绝/取消/异常、长 ReACT 链 |
| PromptTemplateTests | 生产 XML 示例、静默 Task 入口、单次有序话术、无 Task 不关闭、目标转移询问/释放教学、模板变量及目录投影 |
| GenerationRoundTests 的 compact 用例 | JSON/文本/scalar/空值、业务 null、同名多调用序号、拒绝未执行、未知效果、部分成功/取消、内部完整 journal 与 provider ID 隔离 |
| ConversationHistoryTests / HistoryToolTests | 完整消息/请求证据、SQLite 重开、终态 Task 原位压缩、窗口、分页、原生结果及晚到写入、并发冲突与不重放 |
| HistoryIntentTests / ResourceIntentTests | 类型化历史/资源意图、两条 Gateway、提交与呈现、来源/会话隔离、删除/归档及取消 |
| FunctionTokenParserTests / GenerationTrace | UTF-8 分片、XML/实体/作用域、参数、容量、原始证据与无执行解析 |
| AgentConfigurationTests / ActionDeclarationTests | 资源 Catalog、canonical 声明、Skill 绑定、别名/Channel 冲突、固定与模型目录、最终声明覆盖 |
| RuntimeTests / AgentArchitectureTests / CommunicationTests | 接纳、incarnation/来源/会话、root/parent 关联、原子状态、根服务清理与有界输出 |
| ActionContractTests / ActionLifecycleTests / ActionObservationTests | 函数预算、共享执行、资源 lease/fence、Channel/wait、结果预留/重投递、接管、纯取消及完整终态 |
| VoiceTests / SentenceFunctionTests / SpeechPlaybackTests | VAD/ASR、冷加载期间前缀完整性/有序衔接、缓冲时长/内存/包数上限及取消隔离、分段、字幕/合成、PCM handle、播放与半双工边界 |
| AudioCaptureReadinessTests / AudioSampleBufferReaderTests | 首帧准备、格式、mono/FOA/planar PCM、溢出/失败与取消；不打开硬件的原生通知错误保真、中断分类、重复及停止后事件围栏 |
| PhotographyPipelineTests / CameraSamplingTests | 原生帧输入、最新态替换、共享姿态推理、skeleton/gaze 投影 |
| Resource/Provider/Settings 用例 | 私有参数暂存、保存/绑定/呈现顺序、版本冲突、资源准入及失败后状态 |
| Storage 用例 | domain 仓库、配置文档、提交身份、完整消息 checkpoint、容量/损坏/并发与缓存 |
| NexArm/Bluetooth 用例 | 包与几何、反馈／归位、断连与恢复、资源接管、机械臂状态和协议隔离；首次肩／肘水平准备、电机1／4有限位置目标、准入重试／替换、目标死区与前瞻限位、取消后无追加动作；取消／后台清理和最新手动意图的加入／接管 |

Task/Skill 的边界矩阵包括四种预加载接管方式（指定、加载、操作 Action、查询 Action）和完成/失败/取消终态；最后一次闲置时使用/重载、零后重载、独立计数、错误快照、32 个在途 Decision、精确字节/数量预算、批量失败回滚、跨会话取消权及失败提交重试。通过实际 Assistant 请求检查后续目录到期、历史证据保留与内部 ReACT 单次结算。用例数量从源码/测试运行报告获取，不在 README 保存某次执行的计数或通过结论。

## 容器与直接输入覆盖

✅ AgentContainerTests 使用生产 AgentContainerLifecycle 和可控 gate，覆盖冷根失效、真实 ApplicationLifecycle 初始 inactive → active 组合、启动在途取消、并发启停、部分启动回滚、必须暂停、迟到恢复围栏、终态拒绝及原始／清理失败。AgentSpecialistTests 验证 Assistant 前后台切换不控制平级角色。

iOS 条件用例验证 ApplicationContainer 同根缓存、七个子能力身份和跨根隔离，需要 iOS 测试宿主；macOS check.sh 不执行这些用例。具体执行状态归[容器验证](../../docs/validation/Agent-Containers.md)，README 只定义覆盖范围。

| 用例边界 | 观察行为 |
| --- | --- |
| 角色 UI 输入 | 真实子容器请求／回执、单消费者、容量、独立控制、暂停恢复、取消加入、版本／来源隔离；设置私密参数暂存与失败呈现 |
| 存储／公开 State | 无效果构造、打开恢复失败、停止与读写竞争、旧仓库拒绝；公开编码／作用域／代际／预算，完整 Context 不进入公开事实 |
| 原生媒体 | 只读 PCM／CameraFrame 直接消费、原采集序号、布局与新鲜度、唯一有界缓冲、半双工丢弃、停止加入及旧回调围栏 |
| 视觉输出 | latest 替换／会话隔离、离散结果保留、慢消费者、真实溢出、终态排空、输入结束／输出失败、错误证据及呈现 |
| 容器异常 | 同根注入、原始错误与清理错误、取消分类、去重／容量、来源与关联；真实 Gateway／ApplicationControl／Actions 呈现和防递归 |
| 首页准备 | loading／checking／ready 事实、真实呈现调用完成类型、代际及乱序版本、验证失败的完整错误链 |
| 原生执行替身 | 语音权限／准备／停止围栏、播放清理、设备连接恢复和旧反馈隔离；替身不证明物理完成 |

FeedbackActionTests 的 iOS 原生触觉用例通过 HAPTIC_DEVICE_ACCEPTANCE=1 显式启用，保留共享会话还原和清理失败；平台 API 接纳不代表实际震感已确认。其他真实模型／设备 gate 同样必须独立报告。

## 执行与时钟隔离

普通用例并发执行，LiveRuntimeTests 与原生窗口用例在独立阶段串行执行；任一阶段失败仍执行另一阶段并返回失败。涉及真实捕获新鲜度、机械期限、媒体到期和进程级 AppKit 状态的用例使用该阶段，用例内部业务并发仍保留。合成突发用例可显式注入采样间隔；默认 cadence／freshness 用例继续校验生产预算。

## 资源和历史约束

参数容错回归覆盖 XML 未声明属性过滤、无参查询、必填缺失/拼写错误和原始容量拒绝、Tool/固定调用严格授权；设备回归验证 disconnect 附带 id/value/action 仍执行且不向端口透传，适用参数非法值仍失败。模型输出与设备端点使用合成替身，不代表真实 BLE 或物理机械臂验收。

生产 Skill 均由显式 Catalog 加载；模型函数绑定由 Skill 选择，真实参数来自 @Action。请求快照、旧原文及内部关联不被后来的加载或投影改写。Schema、revision、媒体和业务 ID 的断言应取实际资源/提交结果，不用已失效的文档示例代替权限。

模型文字、PCM、图片和执行结果替身必须标明合成。保存/捕获次数、错误后不重放、等待用户、原生配对与持久化失败都应断言真实边界。生产资源当前没有 Skill 依赖，现有资产不能冒充共享/循环依赖图的验收。

## 千问 Action / Tool 回归

QwenWorkflowEvaluationTests 通过实际 Assistant／Gateway 链路运行显式启用的云模型场景，设备反馈和非设备呈现使用合成替身。检查生产 Skill 的 Action-only 请求、协议解析、顺序／wait 与业务流程，不将 HTTP 探针当作完整链路验证。场景数据归 [AgentModelEvaluationTests](../AgentModelEvaluationTests/README.md)，运行入口与凭据隔离见 [scripts](../../scripts/README.md#千问显式实验工具)，结果和已知失败只归 [千问报告](../../docs/validation/Qwen-Workflow-Regression.md)。

## Supervised serial App/Agent acceptance

Serial acceptance calls the same explicit workflow connection operation as the list button and asserts matching native connectivity; it does not claim to exercise SwiftUI navigation.

`NexArmSerialAcceptanceTests` supplies opt-in read-only preflight, Settings/Assistant motor control, Photographer Tool/Settings takeover and full preset trials. `SerialSettingsLink` is a test-only connection façade for App's currently BLE-specific injection seam; every write, query and position receipt goes through the real PlatformKit serial transport. It reuses the SDK's 30 ms budget, keeps one latest telemetry/snapshot/target and no command queue, rejects more than 512 writes or 1024 logged samples, and fences observation/live owners. No motor feedback, IK response, motion success or ATT acknowledgment is fabricated.

```mermaid
flowchart LR
    Manual[UI state and Settings intents] --> Workflow[Production BluetoothWorkflow]
    Model[Fixed model text fixture] --> Assistant[Real Assistant and parser]
    Pose[Injected pose observations] --> Photographer[Real Photographer]
    Assistant --> Output[OutputGateway]
    Photographer --> Output
    Output --> Runtime[Action or Tool runtime and resource coordinator]
    Runtime --> Bindings[Test composition bindings]
    Bindings --> Workflow
    Workflow --> Actions[Production shared Actions controller and planners]
    Actions --> Facade[Test serial connection façade]
    Facade --> SDK[PlatformKit NexArmSerial]
    SDK --> Arm[Physical arm]
    Arm --> SDK
    SDK --> Feedback[Actual timestamped position feedback]
    Feedback --> Facade
    Facade --> Workflow
```

Tests use the real Assistant/Gateway scheduler, domain Action/Tool registration, production business workflow and shared Action recipes. Model text, pose observations and non-device presentation handlers are explicit fixtures; App's private application assembly and native SwiftUI touches are outside this test seam. Finite Agent success requires terminal execution records and measured movement. Tool acceptance is checked separately from measured tracking. Manual submission, cancellation/replacement, an Agent lease bypass, release hold, invalid arguments and disconnected admission have separate checks. No gripper, torque, firmware or calibration change is part of these trials. Failures stop software owners and close the port without movement replay or automatic return home.

Run one explicitly selected physical test per process with `NEXARM_PORT=/dev/cu.usbserial-110` and its gate: `NEXARM_SERIAL_PREFLIGHT`, `NEXARM_SERIAL_ACCEPTANCE`, `NEXARM_SERIAL_TRACKING_ACCEPTANCE`, or `NEXARM_SERIAL_PRESETS_ACCEPTANCE` set to `1`. Default repository checks leave all gates disabled. Stop phone control and clear the physical workspace first. Serial results do not certify CoreBluetooth, radio recovery, native UI hit-testing, real model decisions, YOLO perception or sustained tracking under load. Dated observations belong to [physical acceptance](../../docs/validation/NexArm_Physical_Acceptance.md).

## 待实现

- 真实模型对目标转移、无 Task 完成、主动释放及多轮工作流的遵循验收。
- 相机/Photos、麦克风/声源、声学竞争、持续 BLE/USB/视觉跟踪与原生 UI 验收。
- 可注入 Skill 依赖图及跨进程/持久活跃 worker 的独立验证环境。

执行方法与结果归 [validation](../../docs/validation/README.md)，不在本文件追加运行/安装记录。

Provider 设置新增多 URL 配置重开恢复、删除清理及普通文档无密钥回归。

Provider 名称持久化、默认名称生成、独立弹窗草稿、重复 URL 和空名称校验由自动化回归覆盖；原生弹窗布局与粘贴需设备验收。

✅ providerSettingsStagesHTTPIPConfiguration 覆盖 HTTP/HTTPS IP provider 的私有保存请求准入；使用替身服务，不代表真机局域网连通性。

## 基础相册实施契约

✅ 覆盖旧库丢弃／相册收录／保护保留／分页／删除清理／导入字节与权限失败，区别自动化与真机验收。

Photography完成示例使用明确的“App相册”文案；保持与BasicSkill各自的独立成功示例解析和不结束无关Task的断言。

## 对话打开相册

✅ AlbumNavigationTests使用真实Skill目录／XML解析、NavigationModule／ActionExecutor和ResourcePresentationAdapter，验证album路径、presented回执、非法参数及无效会话不改变路径。

## Container 上下文

✅ ContainerContextTests覆盖读取真实拥有者、来源去重／容量／编码、关闭及同名会话替换、取消、Skill读取集合、Task会话隔离及指令路径。Storage寄存器专属测试已被替换；原有相册／摄影／权限执行回归保留。

## Qwen / GPT-4.1 提示词回归扩展

✅ 使用生产提示词与 qwen-workflows.json 中的有界场景集，evaluate-qwen.py接受三款Qwen与gpt-4.1；每个子进程仅注入对应Provider凭据，GPT使用OpenAI端点。运行前后记录生产上下文／Skill／解析与执行源hash，不修改提示词或放宽断言。报告保留失败与实际响应；本轮使用合成设备／仓库，不能替代真机验收。

## Gateway container ownership

✅ GatewayContainerTests covers App-scoped identity, inert construction, once-only configuration, failure propagation, cached-port fencing, terminal controls, scheduled/direct cancellation, joined native cleanup, root replacement and host ordering using synthetic functions and resources. Observation-session coverage checks bounded diagnostic isolation and App-root cleanup. SoundSourceTests exercises the root-owned observation path with synthetic PCM, without real inference or device control.

## Actions execution chain coverage

ActionsContainerTests exercises pure preparation, credentials, both call protocols, resource permits, budgets, output validation, bounded retention and joined cleanup. GatewayContainerTests uses actual ActionsContainer ports with neutral endpoint/scope and root lifecycle fixtures. ContainerExecutionFixtures supplies legacy scenario constructors in tests only; production has no registry-based Gateway API. Synthetic business/native substitutes do not establish real-device or real-model acceptance.

ContainerContextTests also verifies that an explicitly encoded owner snapshot remains a JSON object through collection and that read failures propagate, rather than encoding Data as a base64 string.

## Passive native State regressions

PlatformStateTests covers deterministic local-time midnight/weekday/leap-day/DST/zone behavior, invalid dates, native observation replacement and unknown values, root admission/resume/stop, context JSON wrapping/re-read and malformed/oversized snapshots. BasicSkill's eight-source contract is asserted. Existing photography/ReACT acceptance inspects all eight sources in actual model requests and preserved request history. Shared and Qwen fixtures use explicitly synthetic FixedPlatformState rather than host device facts; model/device performance and native hardware acceptance are separate.

## Static instruction growth limits

PromptTemplateTests bounds the assembled Assistant static instruction/catalog text to fewer than 25,000 UTF-8 bytes for base Skills and 32,000 with Photography. These are regression thresholds for instruction growth, not token counts or model context windows. Dynamic State and complete-request runtime limits are independent; catalog and safety assertions remain enforced.

## State summaries and explicit queries

ApplicationControl tests cover unknown/admitted/paused/stopped summary reads, per-field sequence fencing, closed scene values and exclusion of raw environment/private result data. Production catalogs reject the removed generic environment address while preserving specific device queries. Shared and Qwen fixtures register an explicit synthetic agents.application owner. Photography/ReACT assertions verify its changes in subsequent actual requests. GenerationRoundTests exercises the registered Bluetooth detail query on Query, real Action feedback and continuation without native Tool calls. These fixtures do not establish real LLM adherence or hardware readiness.

ActionContractTests 直接验证生产 Device.control 生成声明，覆盖携带会话 fence 的连接／忽略与完整可信 UI 操作集合，并检查未知参数、非法操作仍在执行前被拒绝。此测试不访问真实蓝牙或机械臂。

NexArmAimTests 覆盖位置跟踪的方向、死区、有限前瞻/六轴边界和速度/模式/扭矩寄存器拒绝；NexArmBluetoothTests 使用替身验证单目标有限位置包及取消后无追加运动。无真实机械臂验收。

位置跟随回归覆盖 20 Hz 发布、采样率无关的位移/滤波、过时输入和卡顿、慢 Gateway 消费者仅执行最新待发目标、未接纳提案隔离、3 count 更新及 SDK 设备参数边界。混合生产者 BLE 预算和背压测试验证约 33 Hz 连接级上限；替身测试不证明物理平滑或舵机保护。

NexArmArrivalPolicyTests直接验证PlatformKit六轴容差边界、非法反馈配置的原生错误以及原生恢复分类/有界退避；现有动作测试验证SDK观察结果到动作报告的映射。

NexArm relative-motor regression covers encoder conversion, all-axis bounds, fresh measured starts, failed reads without cached fallback, mutually exclusive arguments and rejected writes. Robot workflow scoring rejects wrong axes, order, missing steps and extra moves; live model workflows use synthetic device execution only.

## Reflexive State regression

ContainerContextTests validates passive cold reads, expression override/cancellation/restoration, internal tree paths/depth/capacity/cancellation/partial failures, per-owner health preservation and Skill load/release selection. NexArmBluetoothTests uses an explicit simulated passive link to verify encoder positions, freshness, disconnected-session invalidation and zero control writes/queries. These tests do not establish physical-device acceptance.

ContainerContextTests covers Assistant-owned Business selection, nested-field exclusion, fresh reads, unknown observations, propagation of read failures and independent full Runtime inspection. Native robot tests read the unified State contract.

State audit regressions cover seven-schema wire equivalence and exact UInt64 counters, direct Storage child/tree equivalence without I/O, diagnostic and form-outcome classification, motor outcome/code separation, native quarantine versus valid feedback and invalid category/descriptor rejection.

Single-node regression covers path-only Reference encoding, exact descendant lookup without ancestor/sibling reads, root/catalog zero child reads, weak-owner capability expiry, explicit diagnostic traversal, canonical Skill source equality and unchanged generation/cancellation/bounds. Prior recursive snapshot fixtures are replaced by explicit node catalogs.

PlatformStateTests covers startup seeding, resident reads without resampling, event coalescing, collection failure/recovery, clock updates without readers, generation replacement, foreground reseeding and permission-sharing across child containers. AgentArchitectureTests covers passive Context reads before initialization and after failed restoration. NexArm reflection tests read the publisher-owned resident State without issuing commands or consuming the business stream. Camera read purity is additionally enforced by the architecture audit and compiled in the iOS Simulator build; these checks do not establish physical-device behavior.

State decoupling regression verifies model speech routing stays Runtime without provider preparation, storage root lifecycle failure remains health/issues, permission child reads preserve cached-source errors, scope owner serialization uses stable raw values, and Assistant selection leaves a real producer’s complete Business/Runtime State unchanged.

ActionsContainer regression tests cover native suspension joining before resume and failure preventing admission reopening. SoundSource observation integration explicitly configures Gateway at the host boundary.

The explicit Actions root registration test verifies that repeated registry access returns the supplied root and preserves its stopped state.

Resource-context regressions cover inherited lease resolution, missing-owner rejection and transient-versus-settled holdings. Existing failure-channel tests cover lifecycle-error suppression while retaining journal evidence. Retired App-only health-summary/diagnostic-projection tests were removed with the unused APIs.

聆听控制回归由 ActionAuthoringTests、BehaviorAssemblyTests 与 VoiceTests 覆盖：公开无参数入口、参数拒绝、失败/取消、根会话和弱绑定端点校验，以及许可撤销后回复终态不重开、显式再次启用和不递归排队。受控替身不证明真机麦克风停机或模型退出意图命中。


Perception camera UI intent is exercised through Photographer, fixed Perception Actions and Gateway with a test capability. Camera Foundation snapshot reads are checked for no lazy creation or device activation. Synthetic camera fixtures publish actual-state fields separately from business intent; device results remain independent.

CameraSamplingTests validates native-selected preview/photo geometry, accepting native quarter-turn output dimensions and rejecting incompatible aspect, invalid sizes, over-budget buffers and absent compatible photo formats. WindowGatewayTests verifies Vision aliases resolve only to Camera.Perception Actions while photography retains Camera.Capture; BasicSkill grants neither. PromptTemplateTests also checks that both cold and Photography-loaded Assistant prompts receive the vision/photo routing guidance. Geometry, catalog and prompt tests do not substitute for AVFoundation device capture or real-model intent selection.

NativeImageCompressionTests exercises a synthetic noisy JPEG above4MiB through camera preparation: orientation and aspect are preserved within the4MiB result budget, while the ordinary input budget still rejects that original. Smaller camera JPEGs retain exact bytes/EXIF; explicit input byte/dimension/pixel limits, malformed/oversized input and cancellation fail explicitly. These image-processing tests do not trigger a physical shutter or exercise AVFoundation callbacks.

Camera preparation also uses a padded synthetic mirrored JPEG to verify that normalization preserves visible left/right composition instead of flipping the front-camera image a second time.

## Capture enhancements

CameraEnhancementTests checks pure settings rejection, completion and error handling for configuration and preview unloading, monotonic countdown deadlines/cancellation, domain recording stop/join/audio-release/background behavior, idempotent collection and file-backed video ownership/retention/image isolation. Native recording callbacks and metadata in domain tests are explicit fixtures, not camera/microphone acceptance. PhotographerCameraTests routes all added UI operations through the actual role/Gateway/declared-Action chain. PromptTemplateTests covers loaded aliases, task cleanup ordering and the enlarged Photography catalog budget.

Recording handoff tests exercise the production VoiceRecordingAudioHandoff with an explicit suspended native-stop receipt: microphone sample stop retains ownership, recording admission waits for release, cancellation still joins, and cleanup failure rejects admission. Recording tests assert the actual window-derived angle reaches the native port. Native audio ownership and encoded file orientation still require device acceptance.








系统灵动岛验证覆盖活动容量/owner/revision/generation、原生提交合并/迟到状态/权限失败、阶段提醒去重与上限、后台暂停与根清理、导航白名单；Actions/Skill验证expanded请求与旧自定义几何拒绝、Task身份/中文状态/终态移除。自动化不证明系统动画或真机视觉效果。

灵动岛双呈现回归覆盖通用详情阶段/收起/结束、普通状态拒绝展开、相机优先整活动切换、后台只保留当前活动摘要、真实渲染回执围栏、频谱不重发摘要及系统失败下前台独立。布局检查左右同边距、硬件保护和有界标准圆角矩形；不替代真机动画验收。

Island集成校验新primary/secondary内容与Action解析、指定活动的展示偏好修改、任务自动详情以及系统权限失败与前台独立；图片端口只注册显示资源，不扩大BasicSkill。

VoiceTests的ASR失败回归覆盖创建失败及结束输入后的SFSpeechErrorDomain拒识替身：错误保留、字幕封口、Context及显示回到listening、empty轮次终态、下一句成功发布。此替身验证控制流，不等于Apple ASR真机识别验收。

VoiceTests还验证六次toggle与四来源共768条新revision空闲回执只产生六次聆听Action，迟到busy不能越过已更新围栏；多来源busy更新只在聚合进入/离开占用时各发一次暂停/恢复，替换incarnation的同态事实不重复执行。

ActionsContainer场景回归验证后台保留在途Action、已有准备票据及新请求接纳，原生场景关闭仍执行；完整invalidate继续拒绝新执行。

聆听计时覆盖elapsed编码/非法日期、固定高度与硬件对齐，以及连续聆听跨后台/领域更新保持起点、重新聆听重计。

灵动岛整理回归确认setPresentation目录只保留activityID/size，过时布局/动画请求在纯参数入口拒绝；业务域投影与通用执行保持分离，已有生命周期/优先级/计时回归继续适用。

PlatformSystemStatus测试验证驻留电量未知/充电/低电量字段、网络路径类型及离线语义、非法电量拒绝；不进行原生网络或电池采样。

Bundled Skill catalog validation includes web-browsing/web-drawing and their dependency expansion. The full behavior fixture explicitly supplies WebCapability alongside other optional host capabilities; it does not perform native browsing or generation.

状态覆盖回归从打包Catalog动态枚举全部Skill，逐个执行loadSkills→收集有效useStates→releaseSkills→再次收集。UI/Platform使用真实被动状态读取，iOS专属Actions业务节点与Agent应用摘要为明确替身；验证Web技能依赖、ui.web注册与释放，不调用模型或网络。

Web Skill教学回归逐字符解析实际Instructions.md中的XML示例，使用各Skill及依赖展开后的真实目录，验证别名/参数可接受、依赖调用分轮、创建与修改身份，以及完整已加载提示词的大小预算。它验证教学制品和执行协议一致，不代替真实模型遵循度测试。

Skill状态回归覆盖任意新路径无需Assistant登记、生产者完整Business嵌套、未知来源与有效来源混合采集、诊断固定原因码及关闭/取消/容量边界。旧字段白名单断言改为公开Business与内部Runtime的分类边界。


作品库仅由 Writer 原生工具拥有；回归覆盖 writing 加载失败、Assistant 不暴露作品库入口、仅查询时不创建工作区，以及打开/删除和错误目标；agents.writer 被纳入全部 Skill 状态读取测试的显式 Agent fixture。

WriterAgentTests 通过真实 AgentManager/通信与 Gateway DirectExecutionDispatcher 连接脚本模型和实际作品存储，验证后台接纳、流式编辑、发布与终态回报；呈现是明确 fixture。

Writer 分域回归检查作品库、编辑、只读呈现的 Skill 教学与 native 工具 schema，以及追问后编辑域恢复和无工具内容请求。追问测试核对回答文本进入后续模型请求。工作区回归检查 edit 回执的结构化事实及关联文件，配置回归检查 Writer 专属 Skill 的原生绑定与共享目录隔离。

Writer 续写生命周期回归使用真实 ArtifactService/SQLite、可控非协作呈现与检查点阻塞：跨 session、撤销后及恢复后的旧流被拒绝；取消的 complete 不接纳；变更竞争显式 busy，预览不阻塞追加；release/Actions 根关闭等待在途效果并拒绝迟到操作；已开始的 abort 不被撤销再次取消。文件系统失败夹具检查清理失败持续可见及关闭准入。测试区分工具接纳、文件写入和委托终态，不证明真实模型或原生 WebKit 行为。

Writer 工具集成回归使用真实 Artifacts 服务与呈现探针，验证默认不渲染、单次流式预览及最终刷新、关联文件上下文、搜索分页、目录移动/差异/草稿恢复、显式渲染后发布和运行错误阻止发布。它不替代真实模型或原生 WebKit 验收。

Writer 历史回归验证同一 SQLite 的角色隔离、重开后完整请求/工具结果/取消状态、图像引用的 Writer 输入所有权，以及真实 Gateway 后台创作同时提交 SQLite 历史、经 Gateway 归档。图片字节夹具只验证存储契约，不作为原生解码证据。

Writer 委托回归覆盖默认目录XML Action、保持已有前台 Task、主动事件触发模型、与用户输入 FIFO、重复消息去重、单任务竞争与错误 interactionID 拒收、完成证据满队列后同 ID 重送，以及模型获取前窗口呈现。呈现/模型仍为明确替身，真实 Gateway 与 SQLite 链路独立验证。

Assistant 协议回归检查所有内置 Skill 仅暴露 XML Action、BasicSkill 包含前后台任务控制、身份提示说明协作角色与委托范围；真实 Scheduler 驱动 XML 委托，生产绑定检查 Action scheduled/Tool direct，Writer 独立工具执行保持覆盖。

Writer 委托故障回归通过真实 Assistant XML、Gateway/Scheduler 和 SQLite 验证：模型在 failed 事件中尝试重委托被宿主拒绝；原用户输入内重复委托也不创建第二项任务，新用户输入仍可再次尝试。Writer 端点与模型使用替身，不代表真实模型或设备验收。

Writer失败回归覆盖先list成功后第二次模型请求timeout，实际Gateway记录modelTransport分类并向Assistant传送完整诊断；SQLite重开及通用UI DTO还原诊断，模型/阶段/输入ID/耗时和独立清理原因均保留。模型为替身，不代表真实Qwen请求成功。


Writer 自主任务回归覆盖接收端暂不可用时仍完成创作和发布、同事件重投、暂停恢复、Assistant 关闭后 Writer 继续执行、跨对话阶段汇报及共享 FIFO。语音回归使用受控识别与播放能力，验证连续转写、播放准入、恢复以及明确停止后的采集拒绝。

Writer independence regressions use real Gateway/SQLite with scripted models: rejected user notifications do not retain the creative slot, execution retirement supports successive delegations beyond the live-grant bound, and database reopen redelivers immutable events without another model lease or file creation. Assistant fixtures cover canonical-state reconciliation before new/resumed delegations and stale terminal messages after a new run.

Writer task-Island regressions use actual Gateway direct, Island Actions/UI state and SQLite with scripted model/rendering. A rejecting Assistant does not prevent start/file-step/terminal display; unavailable presentation retains only the latest task state, old-run callbacks are ignored, and root stop joins its publisher. Component tests cover semantic priority independent of producer names, speech/status coexistence, manual collapse and new-stage expansion. No model is asked to call Island tools. These are not native animation or real-provider acceptance.

Writer failure fixtures retain exhausted attempt counts and classified causes. SQLite reopen verifies the active failed native call and unexecuted siblings have paired outcomes. Assistant notification does not redelegate or rerun generation.

## Writer real-provider workflows

`WriterModelEvaluationTests` is gated by `MH_WRITER_EVAL=1` and uses production WriterAgent, authenticated Gateway direct tools, ArtifactService, persistent StorageFiles and SQLite. The requester accepts notifications without creating an Assistant model response. Each new task has its own dialog/project; resume verifies stable task/project and a fresh run. Request traces, complete conversation evidence, artifacts and per-case outcomes are saved outside the repository.

The six cases cover a simple SVG/HTML diagram, multi-file counter, local edits on resume, search/move/remove, Markdown and an intentional JavaScript error followed by repair. The macOS WebKit adapter executes HTML/local JS, records DOM/errors and checks counter clicks. Markdown is displayed as escaped text in this adapter; this is not acceptance of the production Markdown renderer, screenshots, iOS navigation, PDF export or speech. `MH_WRITER_RENDER_EVAL=1` enables a separate no-model WebKit preflight checking changed scripts are reloaded before paid tests.

Evaluation-only bounds are 36 actual requests and a configurable per-case deadline, with explicit cancellation/reporting; production Writer/output budgets are unchanged. Raw model text/tool/usage/failure data and SQLite remain available for stall diagnosis. Run and credential handling: [scripts](../../scripts/README.md#writer-双模型回归). Dated results: [Writer model regression](../../docs/validation/Writer-Model-Regression.md).

Writer continuous-progress regressions cover default partial previews before source completion, slow presentation independent of source intake, coalescing/cancellation and hidden-window suppression, actual-attempt progress, SQLite request metadata/counts/pages and reopen isolation. Assistant progress tests verify latest-value replacement alongside the unchanged formal user/question/terminal FIFO. Natural model termination validates/publishes through actual Gateway effects and stores runtime evidence separately from native model calls. Real-provider evaluation records preview frame times and first non-placeholder content; model latency remains measurable rather than hidden by a production timeout.

默认Assistant Skill回归使用真实UI WindowState和公开State reader，验证未加载窗口Skill也能发现Writer窗口；加载web-browsing后可解析带windowID的调度Action。

受控Qwen场景显式注册agents.writer，避免基础Skill新增来源后在发出模型请求前missing；两个Writer窗口场景验证默认发现、按需加载与真实windowID参数。页面和窗口效果为替身，只有模型/Assistant/Gateway协议实际执行。

Writer evaluator --thinking enabled/minimum changes only the paid experiment Provider configuration (default enabled). Reports record the actual value; production Writer configuration and provider output defaults are unchanged. Use the original diagram goal for latency comparisons.

Writer思考选择回归验证默认minimum、显式开启的凭据/配置往返与重开、Writer配置投影和保存失败回滚；Assistant模型选择保持独立。

Robot Skill exposure is explicit. Assistant starts with BasicSkill and expression only; AgentTaskSkillTests covers discovery, load/release, State selection and frozen earlier catalogs. AgentSpecialistTests exercises scheduled XML loadSkills followed by the Robot Action without a foreground Task or delegation. Deterministic NexArm/Bluetooth/recovery/serial fixtures use loadedRobotAssistantContext to seed a recently loaded robot-interaction Skill through the production state transition before supplying fixed motion text. This fixture setup neither adds robot-interaction to production baseSkills nor changes fixed-host Task policy. Real-provider discovery scenarios start with the unmodified default catalog.

Island lifecycle regressions cover role-owned task publication, all Writer terminal states showing text then ending their own activity, late-progress/run fencing, retained voice activity, latest-state retry and joined shutdown, plus Assistant foreground Skill projection. Writer Gateway/SQLite lifecycle fixtures assert terminal Island text independently of notification delivery.

Island Action integration also covers registered/raw and container-local typed execution equivalence, producer ownership and shared presentation scope, stale generation/stopped endpoint rejection, same-version retry/new-fact replacement, no repeated presentation for frequency-only updates, root rebind, and domain cleanup preserving peer Agent activities. Domain probes implement typed Action calls without a Gateway or UI renderer.

VoiceTests 的语音打断回归使用真实生产者绑定、OutputGateway/InputGateway 和 SpeechPerception，受控播放清理及投递屏障固定取消与空闲事实重叠，覆盖取消前已在途和取消中才提交两种顺序。验证取消仍拒绝普通播放、空闲事实释放半双工占用、关闭许可保持关闭、旧 revision 不复活占用，以及连续五次显式启停可重开感知采集。模型与播放为替身，不代表真机麦克风、光效或灵动岛验收。

Voice regressions verify SpeechPerception emits an empty recognition caption at confirmed onset before ASR text, then completes or recovers locally. Assistant receives completed ASR text. Caption completion, empty/failure recovery and session fencing remain independent of speech playback.

WriterAgentTests 在 LiveRuntimeTests 的真实 WebKit 阶段验证 ArtifactPresentation 的嵌套入口、双槽唯一版本资源、稳定原生文档及回收旧文件后的 reload；窗口完成回执由测试注入，不宣称真实窗口动画验收。

Writer历史SQLite回归核对Provider计时、请求完成时间及run结束时间在重开和UI投影后保留；不将手工注入采样当作真实模型时延测量。

Writer参数化回归加入文件生成中Scene隐藏后仍以原请求数完成的模式；预览测试验证只取消呈现、保留最新意图并恢复。原生Artifacts回归覆盖后台不加载/新建窗口、首次呈现中断保留预留身份、恢复最新文件、重名后缀与副标题、最小化尊重，以及编辑命名/显式改名的持久化和续作保留。

Writer请求标题回归覆盖原生多工具有序去重、短指令与源码过滤、文件生成阶段，以及请求完成后工具仍在执行/失败/取消的区分；SQLite重开后控制器直接投影工具事实与操作标题，无逐行详情读取。

Writer SQLite reopen verifies large native arguments and resumed failure diagnosis; Action input validation accepts source above 64 KiB with existing declaration/identity checks.

Large-source persistence verifies responses above256KiB and tool results above64KiB survive SQLite reopen. Function value validation no longer rejects long observations; input/round identity checks remain independently covered. Writer model evaluation stores its catalog in the same records.sqlite.

WorkspaceRepositoryTests owns relational catalog integration: over-8MiB independent projects, draft/version reopen, concurrent CAS, stale writes and deletion cleanup retry. AppWorkflowTests does not import the SQLite backend.

Agent展示所有权回归在IslandIntegrationTests、VoiceTests和AssistantChatTests：验证各角色通过自身Gateway身份独立发布/结束，展示不可用重试，合成完成与播放完成区分，迟到结束与停机隔离，以及同一路径按LLM/内部来源决定ReACT。模型文本测试和历史预览同时接受显式action与代码展开runtimeAction；诊断装配包含实际Island执行工具。所有语音/模型结果使用测试替身，不代表原生音频或真实模型验收。

Preview regressions cover session-local IDs, FIFO20, failed reservation retention, save flags, reshoot retention and reload, session close/reopen and late-load fencing, scoped history expiry with independent album persistence, visibility suspension, private execution/audit bindings and original-user image merging.

StorageSchemaTests exercises persisted request details referencing one preview across user turns, live-cache history reads without State mutation, new scoped references expiring after close/reopen while album bytes remain independently readable, unscoped/old-session expiry even when album records exist, no persisted preview identity, and independent album reads after database reopening.

DatabaseTableRecordTests round-trips all eleven table models against real SQLite (optional fields, BLOBs, identity and composite keys), checks FK integrity, status updates preserving summary fields, and rollback of device selection/file-index replacement. HistoryIntentTests sends single/global clear requests through UIHistoryContainer → Memory → Gateway → History Action → SQLite and reloads the cleared Prompts projection.

DatabaseTableRecordTests also verifies that unknown schema versions and populated unversioned databases are rejected without deleting records, initializing domain tables or advancing user_version. These are temporary SQLite fixtures, not device migration acceptance.

Native State notification tests wait for observable snapshot changes with a bounded 15-second host-scheduling budget. Exact sample counts, failure recovery and post-stop assertions remain required; this test-only budget does not change production debounce or clock behavior.

Assistant State 选择回归验证每轮快照跟随实际 Skill 选择变化，SQLite decision_json 往返以及删除请求日志后仍保留已记录路径。测试不读取当前 State 重建历史。

## Prompt ownership coverage

AgentConfigurationTests cover v10 public role metadata projected to the v8 compiled contract, missing/invalid/oversized descriptions, unknown fields and identity mismatch. PromptTemplateTests cover instance-permission filtering, exclusion of unsupported peers and private instructions, generic peer Task teaching, and Writer format/retry templates. Existing task, cancellation, library and Writer workflow tests exercise the execution boundary independently of public descriptions.

## Writer JSON prompt evaluation

WriterModelEvaluationTests loads writer-workflows.json when MH_WRITER_EVAL_SCENARIOS is supplied. Each case has isolated SQLite/files and actual Writer/Gateway/ArtifactService. WriterPromptHost uses production ArtifactPresentation, WebPageContainer and WindowState with a mobile viewport; the desktop host acknowledges animation transitions. It records presentation/DOM/window facts and available screenshots; this is not physical iOS acceptance. Provider requests use the same Writer resource assembly and native tool schemas as production. Incoming requests carry goals and optional real work references, never caller-assigned task/workspace IDs. Scenario scoring and synthetic seeds remain evaluation data. Legacy six-case selection remains for historical workflow comparison using the current admission contract.

矩阵宿主通过 bindCommunications 接入实际通信存储，追问回答与取消使用同一持久化通道。无预设回答的等待状态直接记录，不把等待当完成。工具统计来自完整请求轨迹，避免有界历史截断漏算；金额包含断言接受千位逗号，局部替换仍验证完整字节等价。文件、窗口和语义人工复核独立报告。

Writer cohesion regressions use scripted models with real Gateway, Artifacts, SQLite and history: goal-only lookup/edit, clarification then selection, read-before-select recovery without an empty workspace, explicit no-file explanation, premature finish followed by render and identical finish, explanation rejection after editing, and cross-target selection rejection after editing. Admission rejects caller-supplied taskID/workspaceID. Reopen checks preserve provider call IDs, paired outcomes, prior request history and current request/task association. Repository tests verify invalid targets, held leases and cancellation reject atomically. These are deterministic business tests, separate from real-model and native-window acceptance.

Test-owned single- and multi-Skill task.start calls are validated against the default canonical catalog and committed to task/Skill state. These fixtures expose their functions and instructions on the next request without a separate loadSkills; unknown initial Skills leave both task and catalog unchanged. Existing Assistant/Gateway photography tests cover the full request boundary with scripted models.

WriterContainer 分页回归使用真实 SQLite 和 WriterHistory，通过 0/19/20/21/40 条消息、委托及工作区验证准确末页、消息倒序、稳定轮次编号、最多 20 条输出和跨页无遗漏或重复；不调用真实模型。

Writer separation regression uses real temporary SQLite: immutable preflight/workspace scope, two delegations sharing one workspace, exact 20/40 pagination, unique entries and supplemental input, terminal results without a workspace, restart interruption, high message keys independent of revision, tombstones, and fail-closed format reset preserving service configuration. `WRITER_SEPARATION_UI_SEED` optionally exports the synthetic 27-delegation/40-message fixture for the native simulator runner; it does not call a model or read device data.

AssistantSpeechOutput 使用真实缓存/播放与替身 TTS 验证生产 FIFO、输入所有权、溢出、失败保真、停止加入 provider cleanup 和拒绝迟到提交。SpeechRequestProbe 通过窄语音接口检查分段与音频句柄，不模拟合成 Agent 通信。VoiceTests 通过 Assistant 身份验证合成/播放岛与 SpeechPerception 岛独立，旧播放结束不覆盖新活动；真实 Gateway 往返仍验证文本、合成、播放和字幕。原生与真实模型验收独立记录。

AgentCategory 回归验证七个打包角色的分类、配置到 Assistant/Memory Descriptor 的原样传递、通信收窄保留分类，以及两层 schema 对缺失/null/未知/大小写/错误类型和旧版本的拒绝。

ProviderDiscovery 取消回归通过有界信号等待底层取消处理器被调用后释放替身，避免把 UI 主线程异步转发的先后顺序误当成同步保证；生产取消实现保持独立。

GenerationRoundTests 验证业务 Action 抛出原生风格错误且同轮语音输出失败时，仍交付业务观察、继续 ReACT 并接纳下一输入。PromptTemplateTests 验证常驻多窗口规则、摄影保存完成与显式窗口关闭的独立性；提示词契约测试不等同真实模型遵从验收。

Full-duplex fixtures verify buffering until Channel settlement, one request for queued user input and multiple terminal Action results, native-result pairing, interrupt settlement, short forced-tool Decision and conservative fallback, consent policy, and additive SQLite migration. Model and audio-route fixtures use controlled capabilities.

历史完整文本回归覆盖首次批次、ReACT、后续checkpoint、SQLite重开、日志清理、详情/窗口/输入读取与UI双角色完整投影；旧批次仅从身份匹配的记录日志恢复。

请求落盘回归使用真实 SQLite 验证准备/排队/discard 零消息、发送后一次建行、网络失败留证和整Q一行；Writer 委托独立存储。旧格式迁移保留请求、执行结果、日志和外键并清除无调用输入，discard 通过真实 Worker 验证通知且主模型未调用。

多来源批次回归由 InputDecisionTests 与 GenerationRoundTests 覆盖：用户专属分类、Agent 直接入 Q、ASR 时间与身份、SQLite 一批一行、准备失败不落库且保留、Action 单个结果提前请求、成功 Void 不续轮与 native 配对去重。真实模型的选择性回复效果仍需设备验收。

输入时间线回归覆盖跨来源和同秒排序、正文中的仿来源行、设备时区投影、旧 JSON 回放和含旧格式示例的当代正文。PromptTemplateTests 核对输入样例、ASR 澄清规则与既有提示词预算。

ProviderSettingsTests 覆盖 Decision 独立 Provider/模型持久化重开、旧文档可选字段、未配置/无效选择拒绝、共享 Provider 不同角色模型、私有 UI 暂存及呈现链路；InputDecisionTests 的云端路由为 cloud:decision。使用凭据与模型替身，不证明真实服务分类效果。

AudioCaptureReadinessTests 覆盖 AEC 实际启用结果的选择、失败保留、未支持回退及避免重复处理；配置替身不证明设备回声抑制效果。

Assistant 前台结束回归使用 SQLite、模型流替身和实际 ChannelScheduler。模型流与 Display Action 同时阻塞时验证 Control Action 持久化任务终态及折叠来源；分别放行后验证原消息的回复、Action journal 与任务折叠。

PromptTemplateTests 验证 Shared／角色资源归属、Assistant 输入协议隔离、全部 Agent JSON 模板的打包与编译、变量缺失失败，以及用户内容中的模板符号原样保留。Action 描述继续从代码声明投影。

AppWorkflowTests 的网页当前截图通过共享多模态 State 投影验证 Skill 选择、替换、无图模型与新输入附件；原 Assistant Web mediaID 回查测试已删除。原生压缩测试检查分析 JPEG 边界。单槽、窗口生命周期与取消围栏由 AppWorkflowTests/WebWorkspaceTests 覆盖，替身不代表真实 WebKit 或真机验收。

ResourcePresentationTests 覆盖同会话过期刷新/错误呈现不覆盖当前状态，当前错误可见、未来批次/外来会话/根关闭继续拒绝；使用可控在途查询经真实 ApplicationControl/Gateway 验证旧刷新正常结束和后续刷新可用。

Photo countdown regression coverage validates the optional 0…30-second Action parameter before effects, typed endpoint forwarding, no implicit open/configure/retry, and unchanged recording composition. The scripted GenerationRound model emits openCamera, a spoken cue and takePhoto in one response using separate wait groups; a held preview demonstrates ordered execution without an intermediate request. Photography examples parse into two Camera Channel Actions with the countdown attached to takePhoto; spoken examples retain open → speech → capture order and paired waits. Failed opening and unavailable capture report both failures without retries or shutter effects. Native countdown timing/cancellation tests use injected clocks; these are not real-model or physical-camera acceptance.

语音路由回归覆盖同主题的 ASR 片段与最终契约隔离、最终文本接纳时的任务归属、连续识别及受限路线播放准入。语音感知测试验证本地识别字幕与失败恢复，实际原生音频验收单列。
