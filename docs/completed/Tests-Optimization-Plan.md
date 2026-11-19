# Tests 分层与维护优化计划

2026-11-19。状态：已完成。

以 iOS App 的测试金字塔组织现有 Tests：Unit Tests、Integration Tests、UI Tests。日常维护以单元测试和少量核心业务集成测试为主，UI 自动化覆盖少量重要用户流程。先提高现有测试的可理解性和有效性，再合并重复覆盖；不设置测试数量或覆盖率百分比目标。

沿用 [Apple Testing](https://developer.apple.com/documentation/xcode/testing) 的测试金字塔建议。Swift 代码级测试沿用 Swift Testing；UI 自动化使用 XCTest 与 XCUIAutomation，见 [XCTest](https://developer.apple.com/documentation/xctest/)。本计划不要求迁移现有测试框架。

## 测试分层

| 层级 | 标准名称 | 被测边界 | 本项目示例 | 维护原则 |
| --- | --- | --- | --- | --- |
| 单元测试 | Unit Tests | 单个逻辑单元的可观察行为；协作者按需要隔离。逻辑单元不强制等于一个方法或类型。 | XML/句子解析、状态转换、几何、参数验证、模型选择策略、错误转换。 | 快速、确定性；覆盖行为边界与回归，不逐方法机械补测试。 |
| 集成测试 | Integration Tests | 两个或更多真实组件通过生产接口协作；可在被测边界之外替换网络、模型、设备或呈现。既包括模块内部，也包括跨模块。 | SQLite 与文件发布、Gateway 与 Actions、Assistant 结果续轮、Writer 委派与持久化、生产根装配。 | 选择关键接口和业务流程，验证接线、身份、结果、失败与收尾；参数组合尽量由单元层承担。 |
| UI 测试 | UI Tests | 通过实际 UI 自动化操作应用，并断言用户可观察结果。 | Writer 记录页点击、分页、详情与导出。 | 少量、稳定、独立运行；优先高价值用户流程。 |

UI ViewModel、布局算法和请求状态的直接调用属于单元测试或集成测试，不因位于 Tests/UI 或名为 UITests 就成为 UI 自动化。直接调用 WebKit/Metal 原生组件而未操作应用界面的测试属于原生集成测试。

End-to-End Tests（端到端测试，E2E）描述从外部入口到最终结果的完整系统范围；完整用户流程可由 UI 测试承载，但局部 UI 测试不自动成为 E2E。绕过 UI 调用生产 AppComposition 的现有入口归应用级集成测试，不标为完整用户流程 E2E。

## 与层级分开的测试属性

下列术语按含义使用，不与三个主要层级并列成新的目录树。

| 属性 | 含义与使用方式 |
| --- | --- |
| Contract Testing | 接口契约验证，可落在单元层或集成层；记录被验证的格式、权限、身份或完成语义。 |
| Regression Testing | 防止既有缺陷复发的目的，适用于各层。 |
| Smoke Testing | 小范围验证基本可用性，例如单模型通信；不代替完整集成或质量评估。 |
| Performance Testing | 时延、吞吐、内存等非功能验证；区分测量与普通功能测试中的超时保护。 |
| Acceptance Testing | 按产品验收条件验证能力，可由自动化或人工执行；不等同于“使用真机”。 |
| Execution environment | macOS、iOS Simulator、物理设备、真实模型/网络是运行条件，不决定测试层级。 |

每项覆盖记录只需要主要层级、被测边界、外部替身、运行条件四项。优先以行为断言判断层级，不以 import 数量、文件后缀或编译 target 名称判断。

## 目录与命名

保留 Tests 的八个模块职责目录，不新增 Unit、Integration、E2E 目录，不创建公共测试业务库。物理归属、测试层级、SwiftPM 编译 target 是不同维度。

- 单元测试归主要被测对象所属目录；跨模块集成测试归发起工作流的业务所有者，生产装配与 App 宿主生命周期归 App。
- 清晰的现有文件名保留。确需拆分混合文件时，单元套件采用 `<Subject>Tests`，集成套件采用 `<Workflow>IntegrationTests`，UI 自动化套件采用 `<Feature>UITests`。文件名与主要套件相符；辅助文件不使用 Tests 后缀。
- 用例名称描述条件与可观察结果，避免用 live、native、acceptance 等词替代实际被测范围。
- 现有 `IntegrationTests`、`UITests` 等编译 target 首轮保留，不将历史 target 名当作分类依据。Suite 或函数重命名须同步过滤命令和文档，不为命名整齐批量重命名。
- 混合文件优先按 suite 和文档标明边界；仅在职责或执行条件确实不同、维护收益明确时拆文件。新增或移动源码同步 Package.swift 和必要的 Xcode 引用。

## 首轮实施范围

### 第一阶段 分类与测试有效性

- [x] 将 Tests/README.md 更新为三层定义、主要执行入口与替身边界；各模块 README 按文件或 suite 归组，列出主要层级，不维护逐条用例台账。
- [x] 检查 SettingsTransactionTests、Gemma4Tests、D3NativeTests 等使用 `guard #available ... else { return }` 的用例，按框架支持方式报告不可运行条件；显式要求执行的验收在环境不足时明确拒绝，避免空执行被当成成功。
- [x] 检查 DecisionAdapterNativeTests 的输入与筛选：空 rows、未知模型选项、缺少所选模型参考项不得产生零断言通过。新增回归只覆盖这些入口缺陷，不增加模型效果矩阵。
- [x] 记录源码登记、测试发现与启用条件的基线，区分声明数、参数化执行数、跳过和失败，不直接沿用历史统计。

影响文件：Tests/README.md、Tests/App/Settings/SettingsTransactionTests.swift、Tests/ModelKit/Language/Gemma4 下相关测试、Tests/ModelKit/Management/Defaults 下相关测试及其 README；发现相同问题时按相同规则处理。若修复需要改变生产接口，先修订本计划再实施。

### 第二阶段 合并重复覆盖

先审查 AgentTaskSkillTests、GenerationRoundTests、WriterAgentTests、NexArmBluetoothTests、ConversationHistoryPresentationTests 等职责较多的文件，并对照其底层单元测试。文件大小只是审查入口，不是拆分或删测试的理由。

| 处理 | 判定条件 |
| --- | --- |
| 保留 | 保护独立业务不变量、历史缺陷、不同生命周期或独立失败/清理语义。 |
| 参数化 | 被测路径、准备与断言相同，仅输入和预期不同；参数名称应能定位失败场景。 |
| 合并跨层重复 | 单元层完整验证输入边界，集成层保留真实接口协作和一个代表性拒绝，不在每条链路重做同一参数矩阵。 |
| 删除或替换 | 已证实与其他用例覆盖相同不变量，或仅验证退役实现/fixture 自身；先记录承接用例，再删除旧断言。 |
| 拆分 | 同文件包含不同被测职责或执行条件，且在现有目录内拆分能明确所有权；同步编译成员和引用。 |

- [x] 每次合并或删除在变更说明中列出“旧场景 → 承接用例/保留断言”，不以数量下降或更快通过作为充分理由。
- [x] 保留资源所有权、容量拒绝、迟到回调、取消 join 和副作用不重放的独立断言。
- [x] 等待优先使用可控信号；涉及真实时间的既有测试继续在串行阶段运行，不放宽生产期限或隐藏失败。
- [x] 按实际改动更新 owning README；历史诊断夹具仅在引用与独立覆盖均确认后移除。

### 第三阶段 固定核心集成覆盖

优先复用现有用例。每条核心流程以正常完成和最重要的失败或取消为起点；只有存在独立风险时增加分支，不将“每条两项”作为硬上限，也不另写同义大场景。

| 核心流程 | 主要归属与现有入口 | 必须保留的边界 |
| --- | --- | --- |
| App 生产装配与生命周期 | App/Composition、App/Lifecycle；ProductionCompositionAcceptance | 实际根启动、请求可达、前后台、stop join、停止后拒绝；手工服务图与生产接线分别标明。 |
| Assistant 执行与结果续轮 | Agents/Core、Agents/Assistant；GenerationRoundTests、AssistantChatTests | 真实 Gateway/Actions 接口、结果关联、继续请求、取消后不重放。 |
| Writer 委派与发布 | Agents/Writer；WriterAgentTests、WriterWorkflowTests | 接纳、实际文件/SQLite 提交、终态与通知独立、失败清理。 |
| 语音交互 | Agents/SpeechPerception、Actions/Speech；VoiceTests、SpeechPlaybackTests | 最终识别输入、回复输出、音频所有权、停止后的旧捕获/结果拒绝。 |
| 摄影与媒体保存 | Agents/Photographer、Storage/Database；PhotographerCameraTests、PhotoFeedbackTests、AlbumTests | 图像身份、保存后可读、部分失败保留、不重复拍摄/提交。 |
| 设置与模型资源 | Actions/System、Agents/Assistant、App/Settings、App/Resources 的现有测试 | 校验、持久化、应用、回执和失败后的确认状态。 |

- [x] 核对六组流程各自的实际覆盖及运行入口，已有断言直接承接。
- [x] 仅为证实的接线缺口增加最小集成回归。生产根下 Assistant/Writer 的业务请求优先核对，但不强制将全部业务组合进一个大 E2E。
- [x] 历史、窗口/Web、视觉跟踪等已有有效测试继续保留；它们归所属单元/集成层，相关变更时执行，不再为分类额外复制场景。

Keychain、BGTask、真实摄录/Photos/BLE、UI 可访问性及长时间性能属于相关能力的后续专项工作，不作为本次 Tests 整理的全面新增测试清单。已有原生和真实模型入口保留；模型质量矩阵仍由 experiments 独立拥有。

## 执行与文档边界

继续使用 scripts/check.sh 运行默认工程回归及隔离的 LiveRuntimeTests/NativePresentationTests；保留现有串行与失败状态传播。真实网络、权重和物理动作保持显式 gate。原生 App 装配、WebKit 和 Writer UI 继续使用 scripts/simulator 现有入口，不与计时敏感回归并发运行。

Tests 拥有断言与夹具；scripts 只编排。Tests 与 experiments 不互相读取源码、数据、配置或结果，唯一共享制品位置仍是 Models。此次不改变生产模块接口和依赖，不需要重写 MobileHarness 总体技术设计；若实施触及生产边界，应先补充设计范围。

计划与待办仅保留在本文件。实施后 Tests/README.md、受影响目录 README 和必要的 scripts/README.md 描述实际分类、入口与限制。验证结果归 docs/validation，不覆盖 [历史修复证据](../validation/Module-Test-Repairs.md)。

## 验收标准

1. 当前测试可以按 Unit Tests、Integration Tests、UI Tests 理解和定位；层级与环境、专项目的不混写。
2. 每个删除/合并的有效场景有明确承接；不存在为减少数量而删除独立错误、取消或所有权断言。
3. 已修复的入口不能因空输入、筛选为空或不支持平台而误报实际验收通过。
4. 核心集成流程有可定位的现有或新增用例、被测边界及运行方式，无需建立逐条测试管理系统。
5. 纯文档变更检查事实、链接与 git diff --check；代码变更先运行相关定向回归，再运行 ./scripts/check.sh，完整 Xcode 可用时运行 ./scripts/build-ios.sh。不因重分类自动运行真实模型或硬件。
6. 源码成员、测试发现和过滤引用一致；数量变化附原因。工程测试、构建、Simulator UI、真实模型与设备验收分别记录通过、失败和未执行。

## 本轮文件调整

在保持全部既有目录、target 和串行阶段的前提下实施以下拆分；函数名称和行为断言保留，参数化合并除外。

| 原位置 | 调整与所有者 |
| --- | --- |
| Tests/PlatformKit/Connectivity/NexArmBluetoothTests.swift | 底层 BLE 机制保留为单元测试；工作流与 fixture 迁至 Actions/NexArm/NexArmBluetoothIntegrationTests.swift；独立连接策略/规划断言归 Actions/NexArm/NexArmConnectionPolicyTests.swift；两个纯 UI 控件状态用例归现有 UI/Settings/BluetoothConnectionStateTests.swift。 |
| Tests/Agents/Core/GenerationRoundTests.swift | 前四个纯观察值转换用例拆至同目录 GenerationObservationTests.swift；真实轮次协作和其私有 fixture 保留原文件。 |
| Tests/UI/Window/WriterRecordsNativeAcceptance.swift | 重命名为 WriterRecordsUITests.swift，XCTest 类同名；同步 simulator 脚本、Package.swift、Xcode 导航与当前 Tests 文档，编译开关保持。 |
| Tests/App/Settings/SettingsTransactionTests.swift | 两个相同保存流程合为参数化单元测试，分别保留确认提交与失败后恢复断言。 |
| Tests 中带平台提前返回的用例 | 普通回归使用函数级 @available；显式真实模型验收在不支持环境抛明确错误。CoreAI 条件编译缺少能力时明确失败。 |
| Tests/ModelKit/Management/Defaults/DecisionAdapterNativeTests.swift | 提取测试侧输入校验，覆盖未知/空选择、空参考集、缺少所选模型、非法 kind 和空 tokenizer rows，加载前拒绝。 |
| Tests 各能力 README | 按文件/用例组明确 Unit Tests、Integration Tests、UI Tests、外围替身和运行条件；清除因迁移失效的当前引用。 |

上述调整不新增真实模型请求，不引入生产 API。新增输入校验回归使用内存 JSON 与合成参考行。重复覆盖审查保留独立不变量；除同路径设置事务参数化外，其他大文件不因长度被机械删减。

## 完成记录

2026-11-19 完成模块内分层索引、混合文件拆分、UI 自动化命名、设置事务参数化和无效通过修复。六组核心集成覆盖复用现有用例，独立不变量保留。定向回归、完整 check.sh 与五个 iOS Simulator scheme 构建通过，详见 [分层验证](../validation/Tests-Layering.md)。原生 UI 点击、真实模型和设备专项未运行，不计为本次通过。
