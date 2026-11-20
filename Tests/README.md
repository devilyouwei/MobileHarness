# Tests

## 测试分层

按 [Apple 测试金字塔](https://developer.apple.com/documentation/xcode/testing) 使用 Unit Tests、Integration Tests、UI Tests。单元测试承担业务规则与边界，集成测试验证真实接口协作，UI 自动化覆盖少量重要用户流程。模块目录表示所有权，SwiftPM target 表示编译边界，两者均不直接决定测试层级。

| 层级 | 边界 | 示例 |
| --- | --- | --- |
| Unit Tests | 一个逻辑单元的可观察行为，外部协作者按需隔离；不要求一个方法对应一个测试。 | 参数、解析、状态机、布局、选择策略与错误转换。 |
| Integration Tests | 多个真实组件通过生产接口协作，包含模块内、跨模块、持久化和原生框架集成。 | Gateway/Actions、Writer/SQLite、生产装配、WebKit/Metal。 |
| UI Tests | XCTest 与 XCUIAutomation 操作实际应用 UI，断言用户可观察结果。 | WriterRecordsUITests 的导航、分页、详情与分享。 |

ViewModel 和几何的直接调用属于 Unit Tests；实际原生视图挂载、WebKit/Metal 框架调用属于 Integration Tests，不因名称含 UI/native 就成为 UI 自动化。E2E 描述完整外部入口到最终结果的系统范围，局部 UI 测试及绕过 UI 的装配测试不宣称完整用户流程 E2E。

Contract、Regression、Smoke、Performance、Acceptance 描述目的或类型；模拟器、真机、真实模型/网络描述运行条件，均与层级分开。混合文件在模块索引标为 Unit Tests / Integration Tests，按被测行为区分，不重复实现另一套同义测试。

## 模块归属

| 模块 | 主要职责 |
| --- | --- |
| [ModelKit](ModelKit/README.md) | 推理契约、管理、制品及语言/语音/视觉适配。 |
| [Agents](Agents/README.md) | 认知规则、角色工作流、通信、上下文和结果续轮。 |
| [Actions](Actions/README.md) | 函数声明、业务执行、设备策略和能力工作流。 |
| [Gateway](Gateway/README.md) | 输入、调度、路由及媒体/结果传输。 |
| [PlatformKit](PlatformKit/README.md) | 原生平台事实、PCM/图像与连接机制。 |
| [Storage](Storage/README.md) | 内存、文件、SQLite 与仓库持久化。 |
| [App](App/README.md) | 生产装配、宿主生命周期及应用级接线。 |
| [UI](UI/README.md) | 呈现状态/布局、原生组件集成和 UI 自动化。 |

跨模块集成测试归发起工作流的所有者；生产装配归 App。单元测试归被测对象所属能力。沿用现有目录，不建立平行 Unit/Integration 目录或公共测试业务库。现有清晰名称保留；新拆分文件使用 SubjectTests、WorkflowIntegrationTests、FeatureUITests。

## 执行入口

从仓库根运行。默认检查不下载权重、不读取开发凭据、不控制物理硬件；部分确定性原生组件集成随默认测试执行。

| 入口 | 范围与条件 |
| --- | --- |
| `./scripts/check.sh` | 边界、Python 工程工具、Swift 格式、Swift 两阶段回归和 plist；普通阶段与 LiveRuntimeTests/NativePresentationTests 串行阶段都执行并保留失败。 |
| `swift test --filter compactActionObservationPreservesBusinessContainersScalarsAndEmptyValues` | 结果观察值转换的单元测试示例。 |
| `swift test --filter compactRoundObservationsKeepSameAliasCallsDistinctAndPreserveNativeAndJournalIDs` | 使用实际轮次、执行与 journal 的集成测试示例。 |
| `./scripts/simulator/test-composition.sh` | 独立 iOS 生产装配集成，专用模拟器和临时数据。 |
| `./scripts/simulator/test-webkit-simulator.sh` | 独立 iOS WebKit 组件集成，使用生产页面组件，不代表完整 Writer 用户流程。 |
| `./scripts/simulator/test-writer-records-simulator.sh` | XCTest UI 自动化；要求隔离模拟器及合成 seed，见 [脚本说明](../scripts/README.md)。 |
| Assistant/Writer model smoke | `MH_ASSISTANT_SMOKE=1` / `MH_WRITER_SMOKE=1`，显式 `MH_SMOKE_API_URL`、`MH_SMOKE_API_KEY`、`MH_SMOKE_MODEL`；每个输入/delegate 最多 8 次请求，过滤 assistantSingleModelRequestCompletesThroughGateway / writerSingleDelegatePublishesAndCompletes。 |

Tests 只放 Swift 源码和小型工程夹具，不做模型效果评估或 benchmark（归 [experiments](../experiments/README.md)），也不保存模型制品、`.build`、`.local` 或独立 Package；集成测试需要的权重来自根目录 [Models](../Models/README.md)，由 `./scripts/check.sh` 的边界检查守护。

权重、系统语音、真实服务、串口/触觉和规模测试各自保留所属 README 的显式开关。平台受限的普通回归使用函数级 @available 并报告跳过；已显式启用的模型验收在不支持环境报错。跳过、构建或替身结果不等于真实模型、UI 或设备验收。

## 核心集成覆盖

| 流程 | 所有者与现有用例组 | 观察结果 |
| --- | --- | --- |
| 生产装配与生命周期 | App/Composition、App/Lifecycle；ProductionCompositionAcceptance | 根启动、设置请求、导航、前后台、停止及拒绝迟到请求；手工服务图另行验证顺序和回滚。 |
| Assistant 执行与续轮 | Agents/Core/GenerationRoundTests、Agents/Assistant/AssistantChatTests | Action/Tool 关联、真实业务结果续轮、失败/取消和不重放；模型为脚本替身。 |
| Writer 委派与发布 | Agents/Writer/WriterAgentTests、WriterWorkflowTests | 实际文件/SQLite、委派终态、通知重投及清理；模型/部分呈现为替身。 |
| 语音交互 | Agents/SpeechPerception/VoiceTests、Actions/Speech/SpeechPlaybackTests | 最终识别到回复输出、音频所有权、捕获代际与停止；识别/合成/播放端点为受控替身。 |
| 摄影与媒体保存 | Agents/Photographer、Storage/Database/AlbumTests | 图像身份、保存/回读、部分失败保留与不重复捕获；原生相机/Photos 端点独立验收。 |
| 设置与模型资源 | Actions/System、Agents/Assistant、App/Settings、App/Resources | 校验、保存、应用、回执与错误恢复；凭据和原生服务按测试边界替换。 |

已有历史、窗口/Web、跟踪及诊断集成继续归其所有者。单元层覆盖参数矩阵，集成层保留独立接线与完成/失败不变量；重分类不自动复制场景。

## 编译与数据边界

[Package.swift](../Package.swift) 的 testSources 显式登记 Swift 文件，testNonSources 排除说明和夹具；新增/移动源码同步成员、Xcode 导航及过滤引用。现有 IntegrationTests/UITests target 名与串行 suite 名保留，不冒充测试层级。辅助声明在所属目录/Support 复用，不增加公共测试库。

Tests 只维护 Swift 工程测试及自身夹具。scripts 只编排。模型 case、提示词质量、效果矩阵和推理性能实验归 [experiments](../experiments/README.md)，两者不互相读取源码、数据、配置或结果。唯一共享制品位置为根 [Models](../Models/README.md)，按固定来源/版本/校验复用。

实施记录见 [Tests 分层与维护优化](../docs/completed/Tests-Optimization-Plan.md)。运行结果与限制归 [validation](../docs/validation/README.md)，历史证据不作为当前测试通过结论。
