# IntegrationTests

## 职责与构造边界

通过真实 Agent/Gateway/Action/Tool/Storage 接口和注入模型、设备及呈现端点验证跨模块契约。ActionCatalogFixture 在每个作用域安装相同不可变生产声明；并发、失败与完成使用显式 gate/反馈同步。常规用例不推理真实模型、不控制硬件；真实 provider 和串口验收必须单独启用。

## 当前覆盖

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
| AudioCaptureReadinessTests / AudioSampleBufferReaderTests | 首帧准备、格式、mono/FOA/planar PCM、溢出/失败与取消 |
| PhotographyPipelineTests / CameraSamplingTests | 原生帧输入、最新态替换、共享姿态推理、skeleton/gaze 投影 |
| Resource/Provider/Settings 用例 | 私有参数暂存、保存/绑定/呈现顺序、版本冲突、资源准入及失败后状态 |
| Storage 用例 | domain 仓库、配置文档、提交身份、完整消息 checkpoint、容量/损坏/并发与缓存 |
| NexArm/Bluetooth 用例 | 包与几何、反馈/归位、断连与恢复、资源接管、机械臂状态和协议隔离；首次肩/肘水平准备、未准入重试、死区内独立准备和 reset 后重新准备；包括电机 1/4 单包、死区、准入重试/替换、保持无重发、显式新目标触发的迟到发送异常及清理后新目标 |

Task/Skill 的边界矩阵包括四种预加载接管方式（指定、加载、操作 Action、查询 Action）和完成/失败/取消终态；最后一次闲置时使用/重载、零后重载、独立计数、错误快照、32 个在途 Decision、精确字节/数量预算、批量失败回滚、跨会话取消权及失败提交重试。通过实际 Assistant 请求检查后续目录到期、历史证据保留与内部 ReACT 单次结算。用例数量从源码/测试运行报告获取，不在 README 保存某次执行的计数或通过结论。

## 资源和历史约束

✅ 参数容错回归覆盖 XML 未声明属性过滤、无参查询、必填缺失/拼写错误和原始容量拒绝、Tool/固定调用严格授权；设备回归验证 disconnect 附带 id/value/action 仍执行且不向端口透传，适用参数非法值仍失败。模型输出与设备端点使用合成替身，不代表真实 BLE 或物理机械臂验收。

生产 Skill 均由显式 Catalog 加载；模型函数绑定由 Skill 选择，真实参数来自 @Action。请求快照、旧原文及内部关联不被后来的加载或投影改写。Schema、revision、媒体和业务 ID 的断言应取实际资源/提交结果，不用已失效的文档示例代替权限。

模型文字、PCM、图片和执行结果替身必须标明合成。保存/捕获次数、错误后不重放、等待用户、原生配对与持久化失败都应断言真实边界。生产资源当前没有 Skill 依赖，现有资产不能冒充共享/循环依赖图的验收。

## Supervised serial App/Agent acceptance

Serial acceptance calls the same explicit workflow connection operation as the list button and asserts matching native connectivity; it does not claim to exercise SwiftUI navigation.

`NexArmSerialAcceptanceTests` supplies opt-in read-only preflight, Settings/Assistant motor control, Photographer Tool/Settings takeover and full preset trials. `SerialSettingsLink` is a test-only connection façade for App's currently BLE-specific injection seam; every write, query and position receipt goes through the real PlatformKit serial transport. It reuses the SDK's 30 ms budget, keeps one latest telemetry/snapshot/target and no command queue, rejects more than 512 writes or 1024 logged samples, and fences observation/live owners. No motor feedback, IK response, motion success or ATT acknowledgment is fabricated.

```mermaid
flowchart LR
    Manual[UI state and Settings intents] --> Workflow[Production BluetoothWorkflow]
    Model[Fixed model text fixture] --> Assistant[Real Assistant and parser]
    Pose[Injected pose observations] --> Input[InputGateway]
    Input --> Photographer[Real Photographer]
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

Tests use the real Assistant/Gateway scheduler, domain Action/Tool registration, production App workflow and shared Action recipes. Model text, pose observations and non-device presentation handlers are explicit fixtures; App's private application assembly/behavior adapter and native SwiftUI touches are outside this test seam. Finite Agent success requires terminal execution records and measured movement. Tool acceptance is checked separately from measured tracking. Manual submission, cancellation/replacement, an Agent lease bypass, release hold, invalid arguments and disconnected admission have separate checks. No gripper, torque, firmware or calibration change is part of these trials. Failures stop software owners and close the port without movement replay or automatic return home.

Run one explicitly selected physical test per process with `NEXARM_PORT=/dev/cu.usbserial-110` and its gate: `NEXARM_SERIAL_PREFLIGHT`, `NEXARM_SERIAL_ACCEPTANCE`, `NEXARM_SERIAL_TRACKING_ACCEPTANCE`, or `NEXARM_SERIAL_PRESETS_ACCEPTANCE` set to `1`. Default repository checks leave all gates disabled. Stop phone control and clear the physical workspace first. Serial results do not certify CoreBluetooth, radio recovery, native UI hit-testing, real model decisions, YOLO perception or sustained tracking under load. Dated observations belong to [physical acceptance](../../docs/validation/NexArm_Physical_Acceptance.md).

## 待实现

- 真实模型对目标转移、无 Task 完成、主动释放及多轮工作流的遵循验收。
- 相机/Photos、麦克风/声源、声学竞争、持续 BLE/USB/视觉跟踪与原生 UI 验收。
- 可注入 Skill 依赖图及跨进程/持久活跃 worker 的独立验证环境。

执行方法与结果归 [validation](../../docs/validation/README.md)，不在本文件追加运行/安装记录。


## 历史只读请求接入

✅ UI 的记录分页、消息、归档及授权图片读取也经 MemoryHistoryIntent.query 的实际 Gateway/Memory 接入；不再由 UI 请求适配器直接读仓库。MemoryHistoryReadRequests 为根持有的类型化只读请求暂存，最多四个请求，每个请求一个结果等待者；Signal 只携带随机 ID，结果保留规范仓库返回值。请求/结果有界，120 秒未返回明确超时，取消/停止加入实际读取，迟到结果不更新 UI；不新增模型函数或重放副作用。

## Storage 生命周期回归

✅ StorageRuntimeTests 覆盖构造无数据库效果、重复启停、恢复、原始失败、启动取消/停止竞争、停止等待在途读写、旧仓库关闭拒绝及根图回滚。显式 gate 控制执行顺序；媒体延迟注入覆盖 notReady 不被缓存。

Storage 生命周期回归同时覆盖停止先于启动、损坏数据库无后端回退，以及实际 Storage 启动期间 Scene 非活跃的正常暂停和回滚。

## Storage 依赖

✅ 存储访问使用独立的 State、Cache、Database 和 Files 接口；App 注册根实例，消费者通过构造器获得所需能力。存储容器不接管本目录的业务验证、执行和完成语义。

GenerationRoundTests 的 native-only 模型夹具报告合成参数首样本，验证 driver 到历史仓库保留原始计时，不把工具完成时间作为首 token。

## 公开 State 边界

✅ State 回归覆盖公开编码、作用域隔离、代际/容量/失败、Task 投影与每轮请求。Assistant fixture 显式注入隔离的公开事实源；测试替身和自动化结果不等于真实模型或物理设备验收。

[公开 State 契约](../../MobileHarness/Storage/State/README.md)

✅ 补充会话 interrupt/pause 与真实 close 的区别回归，覆盖近期 Skill 续期保留、运行/等待 Task、公开 task 作用域及恢复后新输入；中断不重放、不累计 idle，关闭仍拒绝旧代际。

✅ 验证静态 system 稳定、每轮唯一最新 State、历史/工具配对不被拆分、上下文预算，以及精简教学后的 Task/Skill/相机既有契约；缓存计数保留并兼容旧证据。

## 千问 Action / Tool 回归

✅ 显式 `MH_QWEN_EVAL=1` gate 使用生产 Assistant、公开 State、Task/Skill 控制及 Gateway，注入真实阿里 Responses 模型和合成设备/仓库执行者。共用场景位于 AgentModelEvaluationTests/Scenarios/qwen-workflows.json；每场景独立会话，按用户轮次断言调用协议、参数、顺序、Task/Skill 及禁止效果。普通检查不访问网络。每场景最多32模型请求、每用户输入最多10请求、每输入180秒；超限失败，取消并加入工作，不自动重试。证据仅含合成输入、实际请求/响应/调用和用量，不含凭据；通过不等于真实设备验收。

相机替身同步发布事实，busy/权限/未开启/照片不可操作使用现有 CameraControlError；拍照不能在 busy 时被替身伪造成功。查询旁支保留 Task，替换确认单独测试；强制 Tool 查询需请求 State 未公开的电源/发现列表，避免把合理的 State 直接回答判错。

✅ 针对 Qwen 实测失败补充调用教学守卫、普通忽略与重拍分支的可解析示例，以及无模板变量/无伪 native 函数示例检查；在有界静态正文预算内允许必要教学。同套53场景保留业务判定；全 Action 迁移另外断言调用协议及实际请求无 native 声明。历史三模型结果保留，当前迁移回归只选择 flash/max。

静态 system 正文预算分别为基础 Skill 22,000 UTF-8 bytes、含摄影29,000 bytes（不含 State/历史），用于约束新增教学的规模；完整请求继续执行现有64KiB总预算。示例由生产解析器验证，不把声明名称保护当作真实模型遵循证明。

定向模板/示例检查已通过；完整云回归及全量自动化失败分别见[优化验证报告](../../docs/validation/Qwen-Prompt-Optimization.md)，不以定向通过替代全量验收。


## 分类异常诊断

✅ 注入确定性模型协议失败，验证 Agent 终止控制、类别/代码/轮次、请求证据和无执行/无重试；保留原取消及部分效果行为。

✅ Implemented: bundled Skill regressions assert Action-only queries, Query Channel, value feedback, retention and Task adoption. Generic native/mixed protocol tests remain. Qwen full-suite assertions require all Skill calls to be Actions and every actual request to have no native declarations; original 53-case business expectations remain unchanged.

✅ Implemented: FixtureGenerationOutputs accepts explicit synthetic Action completion/failure outcomes, so query-retention fixtures feed exactly one correlated value result instead of a completion followed by duplicate feedback. Generic native fixtures stay independent of bundled Skill registration.

## Platform 根、设备接入与同帧呈现

PlatformContainerTests 验证注册隔离、根失效/恢复、重复停止和保留断开失败；DeviceInputTests 验证原生媒体适配、独立订阅、FIFO 溢出和输入取消加入；NativeAttachmentTests 验证字符串参数不能伪造附件；MediaTransportTests 验证慢媒体呈现只保留最新包且不阻塞离散输出。构建与运行证据见 [专项验证](../../docs/validation/PlatformKit-Containers.md)。

## 视觉停顿恢复修复

✅ 新增媒体过期后继续输出/新鲜媒体拒绝仍失败、模型忙后恢复/连续三次停止/永久错误立即停止/恢复等待可取消的回归。

✅ 验证原生回调单代围栏在关闭后拒绝迟到包，慢观察者溢出不影响另一个消费者，广播错误保留。

## 视觉静默停止与诊断补齐

✅ 新增视觉会话输入结束/错误等待终态排空、输出失败取消加入输入、用户取消不报故障、卡住/过期健康快照和视觉异常 Agent 分类与 toast 的行为回归。

✅ 图像接纳只做会话、新鲜度、单调序号及类型验证，原子替换 latest 槽；移除接纳前未使用的上下文快照读取，避免帧接纳等待上下文持久化写锁。真正开始推理时仍读取已提交快照。回归使用被阻塞的真实仓库 commit 验证接纳能独立返回。

✅ 真实 VisionPerception 终态经绑定 Gateway consumer、失败快照订阅映射到 Agent 异常与 toast，验证原始错误、会话和输入关联保留。

## 视觉 queueFull 修复

✅ 增加慢视线/姿态广播消费下数百次更新只交付首个和最新值、离散输出不受阻、原始派发错误不被 queueFull 覆盖、FIFO 真溢出携带队列详情、不允许 Action/定向通信误标 latest 的回归。

✅ 最新状态替换键在不同会话间隔离；超过 16 个不同键明确拒绝，验证不会通过最新态策略引入无界缓存。

## UI 容器与相机能力注入

✅ 补充 AppStorage 的 UI 根/子能力缓存一致性、跨根隔离及 CameraCapturing 替身接口回归；不将 iOS-only Coordinator 的编译或主机替身当作真机功能验收。

## 统一输入专项

✅ DeviceInputTests 覆盖统一草稿/信封、业务身份与因果、内容/反馈伪造拒绝、合成传感器 schema、静态/动态合并、容量/取消/关闭与会话/incarnation 隔离。既有业务意图回归验证兼容；替身不证明硬件采集。
