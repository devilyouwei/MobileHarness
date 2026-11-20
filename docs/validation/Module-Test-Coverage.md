# 模块与链路测试覆盖审查

2026-11-18。对照 [总体设计](../../MobileHarness/README.md) 的八个模块与关键流程，检查 Tests 源码、Package.swift 成员表和同日 [最近一次完整检查记录](Scripts-Organization.md)。本次是静态职责/功能覆盖审查，没有重新运行全量测试，也没有采集行/分支覆盖率。用例数量不代表功能覆盖率。

## 结构与基本功能

Tests 一级目录与 App、Agents、Gateway、Actions、ModelKit、PlatformKit、Storage、UI 八个模块一致。172个 Swift 文件全部登记在 testSources，无重复和不存在路径。成员登记不等于默认执行：原生 iOS 验收文件有条件编译，模型 smoke 有显式开关；编译 target 也与物理模块目录不一一对应。

| 模块 | 已有基本功能覆盖及代表文件 | 限制 |
| --- | --- | --- |
| App | [ApplicationLifecycleTests](../../Tests/App/Lifecycle/ApplicationLifecycleTests.swift)：依赖顺序、启动回滚、前后台、取消与清理；Settings/Resources/Presentation 目录覆盖操作事务与状态投影 | 生产装配链缺少直接回归，部分 App 目录内容实际已归 Agents/Actions |
| Agents | [AssistantChatTests](../../Tests/Agents/Assistant/AssistantChatTests.swift)、[InputDecisionTests](../../Tests/Agents/Assistant/InputDecisionTests.swift)、[WriterAgentTests](../../Tests/Agents/Writer/WriterAgentTests.swift)：请求、上下文、决策、协作、失败、记录与恢复；Photographer/SpeechPerception 覆盖感知 | 部分提示词契约和 Decision/取消断言当前失败；真实模型 smoke 默认关闭 |
| Gateway | [GatewayContainerTests](../../Tests/Gateway/Output/GatewayContainerTests.swift)：配置、身份、旧端点拒绝、准入、容量、暂停/停止 join；调度/资源测试还散落 Actions | 一级目录正确，内部归属不完整，不能按本目录文件数判断覆盖 |
| Actions | [ActionsContainerTests](../../Tests/Actions/Execution/ActionsContainerTests.swift)：准备、执行与失效；Contracts、System、Camera、NexArm、Speech、UI 覆盖参数/业务执行与失败 | 设备/native 端点大量使用替身，真实效果需独立验收 |
| ModelKit | [ModelLifecycleTests](../../Tests/ModelKit/Management/Runtime/ModelLifecycleTests.swift)、[ChatExecutionTests](../../Tests/ModelKit/Management/Defaults/ChatExecutionTests.swift)：加载/卸载/并发/取消/清理；Core、Download、Language、Speech、Vision 有各自契约与适配测试 | 原生权重、系统能力及网络测试按环境显式启用，不是每次默认检查都推理 |
| PlatformKit | [PlatformStateTests](../../Tests/PlatformKit/Core/PlatformStateTests.swift)：状态种子、订阅、迟到回调、权限事实；Audio/Connectivity/Vision 覆盖 PCM、协议、图像处理 | 麦克风/相机/蓝牙实际授权与系统恢复并未被合成输入证明 |
| Storage | [StorageRepositoryContractTests](../../Tests/Storage/Database/StorageRepositoryContractTests.swift)、SQLiteRecordTests、WorkspaceRepositoryTests：文件边界、缓存/租约、事务、版本、持久化与重开 | 有真实临时文件和 SQLite 集成，并非全部内存替身；整 App 重启仍需生产装配覆盖 |
| UI | [UIContainerTests](../../Tests/UI/Container/UIContainerTests.swift)：根/子能力身份、失效与清理；Settings、Navigation、Window、Camera、Presentation 覆盖状态/几何/回执，WebPageTests 含原生 WebKit | 状态与 macOS WebKit 不能替代 iOS 点击、布局、系统分享和真机效果 |

结论：八个模块均有实质性基础测试，没有发现整个模块没有测试的情况；不能据此宣称所有公开接口、分支或生产闭环都已覆盖。

## 跨模块链路

| 链路 | 直接证据 | 判断 |
| --- | --- | --- |
| 语音转写 → Assistant → 输出调度 → 合成/播放与字幕 | [VoiceTests](../../Tests/Agents/SpeechPerception/VoiceTests.swift) 的 voiceGatewaysRoundTripThroughSayAndPrint | 真实业务组件连接，ASR/LLM/TTS/native 播放注入替身；最近执行通过 |
| Assistant → Gateway → Actions → 结果回流/继续请求 | [AssistantChatTests](../../Tests/Agents/Assistant/AssistantChatTests.swift)、[ActionExecutionTests](../../Tests/Actions/Execution/ChannelSchedulerTests.swift) | 已覆盖关联结果、拒绝、取消和 Channel/wait；不是整个 App 装配启动 |
| Writer 委派 → 文件发布 → 记录持久化 → 历史回读 | [WriterAgentTests](../../Tests/Agents/Writer/WriterAgentTests.swift) 的 writerBackgroundRoleUsesDirectGatewayAndPublishesActualArtifact、writerDelegationAndWorkspaceMessagesHaveImmutableScopes | 脚本模型结合实际工作流/存储，最近两组执行通过；单模型真实 delegate smoke 另有显式入口 |
| 摄像头帧 → 视觉推理 → 展示/摄影/跟踪 | [PhotographyPipelineTests](../../Tests/Agents/Photographer/PhotographyPipelineTests.swift)、EyeTrackingTests、PhotographerCameraTests | 最新帧、慢消费者、取消与控制准入有覆盖；visionKeepsOnlyLatestAndNeverOverlapsOrReplays 最近通过，真实摄像头/电机效果不能由此确认 |
| 设置 → Provider/模型选择 → 保存恢复/资源管理 | [SettingsInteractionTests](../../Tests/App/Settings/SettingsInteractionTests.swift)、[ProviderSettingsTests](../../Tests/Actions/System/ProviderSettingsTests.swift)、ModelResourceInteractionWorkflowTests | 有确定性链路回归，但当前识别模型清单断言失败；完整真实下载部署需独立验收 |
| 相机保存 → 媒体仓库 → 相册/呈现 | [PhotoDispositionWorkflowTests](../../Tests/App/Camera/PhotoDispositionWorkflowTests.swift)、[AlbumTests](../../Tests/Storage/Database/AlbumTests.swift)、AlbumNavigationTests | 有分段集成和“保存已提交后反馈失败不回滚”验证，不等同整条真机操作 |
| App 启停 → Actions → Gateway → Agents | [GatewayContainerTests](../../Tests/Gateway/Output/GatewayContainerTests.swift) 的 hostOrdersActionsGatewayAgentsAndRetainsBindingsThroughCleanup | 最近通过，但手工构造 ManagedService，agents 节点是闭包探针；只能证明该手工图的顺序 |
| 页面隐藏/后台 → 执行保留或取消 → 恢复/停止 | ApplicationLifecycleTests、PersistentHomeNavigationTests、UIContainerTests、WindowExecutionTests | 有阶段/代际/清理回归；实际 OS 生命周期回调接入仍属生产装配缺口 |

## 问题与修复优先级

1. **优先恢复已有测试的有效性。** 最近完整检查普通 IntegrationTests 为1200项/9个 issue，AppWorkflowTests 有缺少 injected Action declarations 等失败，Writer 取消测试还停在无超时的 `while await model.requests.isEmpty`。串行 LiveRuntimeTests 为228项/1个 issue。应更新过期契约/夹具，使用有界同步检查真实失败；不能把当前红色套件当作可靠基线，更不能删除断言换取通过。
2. **补生产装配冒烟回归。** Tests 中未找到 AppComposition、ServiceFactories、ModuleRegistration、ApplicationPresentation 的直接调用；Package.swift 的 AppStorage 明确排除这些生产装配文件。现有 ApplicationContainer 注册身份测试、手工生命周期图以及 iOS 构建不能验证实际接线。建议用生产装配入口加可替换模型/原生端点，验证根启动、一次 UI/Assistant 请求、一次 Writer 委派、前后台与 shutdown 的真实终态。保持少量请求，不引入效果矩阵。
3. **纠正目录责任错位。** PlatformContainerTests 中 uiRegistrationSharesCameraWithItsRootAndIsolatesScopes、uiLifecycle*、modelRegistrationSharesFourPortsAndIsolatesRoots 属于 App 装配或对应根能力；ActionExecutionTests 大量直接验证位于 Gateway 的 ChannelScheduler；Tests/App/Writer/WriterWorkflowTests 验证的 WriterWorkflow 实现在 Agents/Writer。应按实际被测所有者拆分/迁移，跨模块测试由发起工作流的所有者收纳，生产组合测试归 App，保留现有编译边界。
4. **明确 smoke 与验收执行层。** Assistant/Writer 单模型 smoke 已存在，但最近检查均跳过；WebSimulatorAcceptance 和 WriterRecordsNativeAcceptance 需要独立脚本/编译开关。应记录独立运行结果，不能用默认套件统计推断它们已验证。不以真实模型或硬件替代可重复的工程契约测试。
5. **让导航反映可执行覆盖。** 当前若干 README 仍是累积说明，包含旧归属与待办；后续整理应保留“功能 → 用例 → 执行方式 → 最近结果”的简洁索引。默认工程测试虽物理分离，仍与 experiments 的 helper 共用部分编译 target；这是已记录的编译耦合，不意味着效果矩阵应计入工程覆盖。

本次仅审查并记录，不修改测试或生产实现。无需为审查再跑构建；依据的执行结果来自同一工作区紧邻上轮检查，后续代码变更后应重新验证。

## 后续修复

本报告以上为审查时快照。目录错位、声明夹具、退役断言、无界等待和生产装配缺口的后续处理见 [模块测试修复验证](Module-Test-Repairs.md)；历史失败不作为修复后结果。
