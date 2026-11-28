# Signal 非 IPC 改造验证

日期：2026-11-19。分支：`feat/signal-redesign`。范围与设计见[需求及实施记录](../requirements/technical/Signal-Architecture-Redesign.md)。用户选择保留现有模块目录，各模块拥有监听契约；未新增 SignalKit 或源码目录。IPC 独立保留在需求中。

本次覆盖外部 Media/State/Sensor/Request SignalListener、Gateway 类型化 Request/Reply 与显式频道事件、有界独立消费者分支、signals 配置及代码处理器校验、完整任务操作、内部 interruption、动作调用快照、历史兼容与任务事件游标。

新增或更新回归覆盖：

- 单消费者句柄、重复迭代拒绝、源解除注册与旧代际围栏；传感器单位、量程、频率、有效性和缺失值。传感器使用构造值，不声称存在压力/温度硬件。
- 请求无需源 inbox、未知协议、类型/预算校验、超时取消与加入、循环请求拒绝、端点替换和可信清理预留。
- 显式频道/协议绑定、同协议事件变体、独立慢/快消费者 FIFO、单分支容量拒绝和取消只加入其自身分支。
- 请求完整处理器、v11/v9 配置与旧字段拒绝、协议能力目录、静态来源与发布匹配。
- 调用快照原始/空/缺失参数、大小拒绝、归档恢复、不可变证据冲突；任务事件消费游标不越过未消费前缀；20261113 原文/待投递记录的非破坏迁移。

## 验证记录

| 检查 | 结果 |
| --- | --- |
| Gateway/监听器首轮定向测试 | 11 项通过；当时覆盖请求、事件独立分支、Sensor/Media 监听器。此结果是中间版本证据，不能代替最终全量检查。 |
| 扩展通信/存储测试首轮 | 70 项中出现旧协议与旧“丢弃”预期不匹配，已据新契约修订；后续完整检查还发现 UI 多步反馈与直接返回被错误合并，已拆为 executeReturning/executeDirect。 |
| 首轮全量检查 | 未通过，随后中止旧运行。暴露旧目录权限预期、配对反馈路径及隔离角色绑定问题。该次日志存在并行写入，不能作为最终计数证据。 |
| iOS 构建第一轮 | 五个 scheme 均 BUILD SUCCEEDED，最终 Agent/Skill、Live Activity、中英文本地化资源检查通过。随后源码修订须再次构建。 |

早期产物带有误归属 Agents 的 yolo26n-pose.mlmodelc。Package.swift 显式排除 Resources/Models 后，Xcode 移除误编译输出；保留模型源资产。此前 App 中的生成 Agents bundle 移至 `/tmp/mobileharness-signal-old-agents-app.bundle`，重新生成并通过资源检查。

声明字节预算的整数载荷测试不等于实际内存压力测试。自动化工程验证不等于真实模型、原生 UI、物理设备或多源全双工性能验收；本次未运行这些专项，也未运行真实双进程 IPC。

## 消费者所有权修正前的工程门禁

| 检查 | 修正前历史证据 |
| --- | --- |
| `./scripts/check.sh`（完整 Xcode） | 退出 0。模块边界、8 项 Python 工具回归、严格 Swift 格式、全部普通/串行测试与 plist 检查通过。Integration 普通阶段 1197 tests，串行阶段 231 tests / 210.877 秒；其余测试 target 也执行，不将这些阶段计数误称全仓总数。日志 `/tmp/mobileharness-signal-verified-check.log`。 |
| `./scripts/build-ios.sh`（完整 Xcode） | 五个 scheme 均 BUILD SUCCEEDED：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAppleLLM。主应用 Agent/Skill 资源（73 assets）、Live Activity 和中英文本地化资源验证通过。日志 `/tmp/mobileharness-signal-ios.log`。 |
| `git diff --check` | 通过。 |

最终普通阶段包含原 requester 的 Writer 入站准入、其他发送者修改被拒绝、结果返回原 requester 的新增存储回归。串行阶段包含请求 timeout 真实进入处理器后的取消/join，避免把高并发下未入场前到期误作清理失败；父子停止与任务终止回报、调用取消及容量恢复均通过。协议不支持的正文返回原始 unsupportedContract，调用者取消传播 CancellationError。

最后一次修改将 NexArm 消费启动的初值读取改为已有 reflectedState 缓存，以保证观察不会隐式创建原生驱动；该文件独立格式检查通过，最终 iOS 对象文件生成时间晚于源码修改。对应 Mac 定向回归单独记录如下。

NexArm/Bluetooth 最终定向回归退出 0：一个目标 11 tests / 0.006 秒，LiveRuntimeTests 218 tests / 199.914 秒，均通过。日志 `/tmp/mobileharness-signal-native-final.log`。Mac Actions 对象文件和最终 iOS Actions 对象文件均晚于最后的源码修改；没有把先前二进制测试当作最新调整的验证结果。物理 USB/机械臂专项依默认条件跳过，未将跳过用例记为实机通过。

本轮未新增第三方依赖、目录或模块；保留既有未跟踪的 DecisionBenchmarks/Gemma4Tests 本地目录。代码变更位于 feat/signal-redesign 工作区，尚未提交或推送。原始 Technical_Design.docx 保持不变。

## 消费者所有权修正

发布不再创建订阅或初始化/查询消费者。Writer 按需 publish，无 JSON publication；Assistant 在请求前持有精确生产者、scope、session 订阅，独立补读、消费确认和关闭。Storage schema 20261120 分离 published_at 与 received_at/consumed_at；消费不控制源端 outbox。

定向验证：无订阅/暂停/退订发布、隐私受众、scope/session 隔离、自回调退订、发布与消费独立及迁移用例均已通过。最初恢复用例使用旧 storage fixture 的 task.request，而恢复查询遗漏该已支持别名，造成 90 秒超时；查询已与请求契约的历史别名对齐，主回归改用真实 v1 请求并加入新旧 session 不同的场景。另一条断言误把两个静态语音/中断订阅计为动态泄漏，已明确仅预期这两个静态订阅。最终恢复回归 1 test / 0.058 秒通过，日志 /tmp/mobileharness-owner-recovery-final.log。该次测试后的 worker 取消竞态收尾修订由下述完整门禁重新验证。

首次完整检查在严格格式门禁发现两个闭包混用 trailing closure，已改用显式参数；当次没有进入完整 Swift 测试，不记作通过。日志 /tmp/mobileharness-owner-check.log。

第二轮完整检查普通阶段执行 1202 tests，14 issues；串行阶段另有两个任务夹具在订阅前未绑定有效消息端口。问题包括假设发布自动绑定静态消费者、旧夹具没有订阅能力、依赖消费者恢复/生产者暂停的调度先后、以及错误要求旧任务视图在持久事实已可恢复时仍为空。已改为消费者显式装配和任务匹配断言；不把发布退回同步等待。该次日志 /tmp/mobileharness-owner-check-final.log，仅作为失败及修订证据。随后被动分支诊断改为读取 broker 实际结算，不扫描静态消费者名单。

后续复核移除了请求准入对任务事件的协议特判，并阻止 Agent 发布直接走请求入口。该中间版普通阶段 1202 tests / 65.854 秒通过，但串行停止回归发现认证的宿主终止反馈也被误拦截。现以通用 runtime 来源及 ExecutionOwner 端口保留宿主反馈，不恢复任何发布触发订阅逻辑。两次被替代的运行已主动终止（退出143），不作为完整通过证据；日志 /tmp/mobileharness-owner-verified-check.log 和 /tmp/mobileharness-owner-final-check.log。补充准入回归初次漏传 fixture rootID 导致编译失败，已补齐；日志 /tmp/mobileharness-owner-final-verified.log。

完整复跑 /tmp/mobileharness-owner-accepted-check.log：普通 1202 tests / 64.641 秒通过；串行 231 tests / 213.041 秒，四个 issues 均来自两个尚未显式绑定静态消费者的工程夹具（姿态广播与声源广播）。补充消费方自己的端点装配后，两项定向回归共 0.046 秒通过，覆盖姿态有/无订阅两种参数与新鲜声源绑定；日志 /tmp/mobileharness-owner-static-consumers.log。生产发布路径不恢复初始化消费者。

## 静态订阅调整前的历史门禁

| 检查 | 当时源码证据 |
| --- | --- |
| 完整 `./scripts/check.sh` | 退出 0。边界、8 项 Python 工具离线回归、严格 Swift 格式、各普通/串行 target 和 plist 通过。Integration 普通 1202 tests / 64.837 秒；LiveRuntime 串行 231 tests / 208.131 秒。日志 `/tmp/mobileharness-signal-owner-check.log`。 |
| 完整 `./scripts/build-ios.sh` | 退出 0，五个 scheme 均 BUILD SUCCEEDED：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAppleLLM。主应用 73 项 Agent/Skill 资产、Live Activity 及中英文本地化资源检查通过。日志 `/tmp/mobileharness-signal-owner-ios.log`。 |
| 文档与差异 | 47 份改动 Markdown 的本地目标路径有效；`git diff --check` 通过。 |

本轮工程替身验证包含零消费者时独立发布、暂停/退订后继续发布、不探测消费者状态、不建立隐式订阅、生产者/任务/session 过滤、在当前消费回调中退订、无人监听时的持久终态恢复，以及源端 publication 与消费确认互不控制。Assistant 重启回归使用不同于旧任务的当前 session；不伪造历史活动端点。实物 USB/机械臂按环境 gate 跳过，不记为通过。未运行真实模型矩阵、iOS UI 专项或实机多源全双工/性能验收；IPC 按授权范围未实现。

## Assistant 常驻 Writer 频道的中间验证

下列为需求第 15 节的中间设计记录；其中取消 publication 声明/来源配置校验的决定已由第 16 节替代。对应需求第 15 节。Assistant 启动装配静态监听 Writer，任务表只跟踪 producer/task/session；任务完成不退订，角色停止/替换清理端点。Writer 配置仍无 publication，静态消费者不要求发布者已配置或在线。直接 send 的 Reply/失败路径不变；broker 无消费确认、持久性或迟订阅补发。持久任务记录对账仍由业务消费者拥有。

初次定向回归暴露空 scope 原先只匹配空 scope，造成常驻监听收不到任务事件；已改为空 scope 通配、指定 scope 精确过滤，并拒绝同端点的交叠绑定。另修复重命名漏改的恢复调用、测试缺少 try 和构造终态夹具缺少 delegateID 的编译/验证问题。中间失败日志为 /tmp/mobileharness-static-writer-focused.log、/tmp/mobileharness-static-writer-focused-final.log、/tmp/mobileharness-static-writer-scopes.log，不作为通过证据。

最终定向回归：12 tests / 0.382 秒通过（Writer 状态回归含 20 个参数组合），日志 `/tmp/mobileharness-static-writer-verified-focused.log`。覆盖无 Writer/无任务即建立监听、任务前后静态订阅保持三个、停止/替换清理、未知任务与错误 session 不删除当前跟踪、迟订阅不补发、发布不探测接收状态、直接 send 的实际 Reply/错误，以及频道级多个 scope 与精确 scope 隔离。

## Publication 声明与常驻订阅的当前验证

对应需求第 16 节。任务生产者 Writer、Memory、Photographer、ApplicationControl、Assistant 声明 agent.task / agent.task.events.v1，代码能力目录逐项校验。静态订阅要求来源配置和匹配的 publication；配置合法不要求来源实例在线，publication 允许没有订阅者。移除协议级隐式发布绕过，实际 pub 按本角色声明准入；无消费确认或 broker 补发。Assistant 对 Writer 仍从启动开始常驻监听，任务跟踪不创建或关闭该频道。

此前中间全量运行 `/tmp/mobileharness-static-writer-check.log` 暴露 Writer 工程请求方仍动态订阅，与常驻监听交叠；运行已终止（退出143），不计为完整通过。已改为装配静态消费者并只跟踪任务。中间定向 `/tmp/mobileharness-static-writer-fixtures.log` 曾有 7 个 incomplete 问题；独立 20 任务回归随后 17.138 秒通过（`/tmp/mobileharness-static-writer-twenty.log`）。最终按最新 publication 声明的定向回归覆盖全部这些路径，结果如下。

- 10 tests / 17.810 秒通过，含 Writer 状态 20 个参数组合、目标选择 17 个组合、独立创作 17 个组合、20 次连续任务和恢复，日志 `/tmp/mobileharness-publication-declarations-focused.log`。
- 负向校验覆盖缺失订阅来源配置、来源未声明 publication，以及声明了无对应代码生产能力的协议。合法静态监听不要求生产者运行；无订阅时 pub 成功且不探测接收状态，迟订阅不补发；任务前后监听数不变，停止/替换清理。

### 最新完整工程检查

| 检查 | 第 16 节当前源码证据 |
| --- | --- |
| `./scripts/check.sh`（完整 Xcode） | 退出 0。边界、8 项 Python 离线工具回归、严格 Swift 格式、普通/串行测试与 plist 通过；Integration 普通 1205 tests / 64.343 秒，LiveRuntime 串行 231 tests / 207.918 秒，其余 target 也执行。日志 `/tmp/mobileharness-publication-static-check.log`。 |
| `./scripts/build-ios.sh`（完整 Xcode） | 退出 0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAppleLLM 五个 scheme 均 BUILD SUCCEEDED。主应用 73 项 Agent/Skill 资源、Live Activity 和中英文本地化检查通过。日志 `/tmp/mobileharness-publication-static-ios.log`。 |
| 文档与差异 | 48 份改动 Markdown 本地目标路径有效；`git diff --check` 通过。 |

工程模型/设备替身验证不替代真实模型矩阵、iOS UI 专项、实机多源全双工与性能验收；本轮未运行这些专项，物理设备 gate 的跳过不记为通过。IPC 按用户范围不实现。修改位于 feat/signal-redesign，未提交或推送，保留既有未跟踪本地测试目录。

## 第 19 节：Gateway 回归 Signal 通信，执行 Shell 归 ActionsContainer 的验证

对应需求第 19 节。Gateway 只保留四类内部 Signal 的端点、准入与递送；ChannelScheduler、DirectExecutionDispatcher、ResourceCoordinator 与结果账本迁入 Actions/Support/Shell，并通过中立 ActionExecutionEngine 契约接入。Actions/Support 按职责整理为 Contracts、Function、Call（Action 与 Tool 的绑定/执行同目录）、Shell 四个子目录。

| 检查 | 当前源码证据 |
| --- | --- |
| 边界与格式 | `check-modelkit-boundaries.py` 退出 0；`swift format lint --strict` 无输出。 |
| 测试构建 | `swift build --build-tests` 退出 0。 |
| `./scripts/check.sh` 第二次完整运行 | 退出 0；普通阶段 Integration 1207 tests / 67.754 秒通过，LiveRuntime 串行 231 tests / 206.645 秒通过，plist 检查通过。日志 `/tmp/shell-check1.log`。 |
| `./scripts/build-ios.sh` | 退出 0，五个 scheme 均 BUILD SUCCEEDED。首次运行暴露 iOS 专属代码缺少 ExecutionRuntime 导入和残留 makeCameraRuntime 参数，已修复后重跑通过。 |

首次完整 check.sh 在普通阶段仅有 `resultRedeliveryStopsAtTheLimitAndFailsTheRound` 一项失败：满载并行下 300 ms 的重投期限在第二次重投前已到期。测试期限改为 2 秒后单独运行与完整运行均通过；这是测试时间余量问题，不改变 60 秒设计值，该值仍是未经测量的设计值。

迁移后的执行生命周期用例（暂停/恢复 join 资源与动作清理、重复停止保留清理失败、停机 join 准备中任务、Channel 容量预留）由 GatewayContainerTests 迁入 ActionsContainerTests。Gateway 配置失败用例改为同一执行 Shell 的第二次绑定被拒绝；重复资源定义的拒绝不再由 Gateway 测试覆盖，也尚无 Actions 侧专项用例。未运行真实模型矩阵、iOS UI 专项或实机验收；修改位于 feat/signal-redesign，未提交。

## 第 20 节：Agent 内部控制函数迁入 Agents 的验证

对应需求第 20 节。`task.start/end/send`、`loadSkills`、`releaseSkills` 由 BasicSkill 通过 `useControls` 登记，Assistant 在发射时本地执行，不再经 Gateway 与 Actions；Actions 的 System/Task 模块、TaskControlCapability 及相关装配已删除。

| 检查 | 当前源码证据 |
| --- | --- |
| `./scripts/check.sh` | 退出 0：边界、Python 离线回归、严格 Swift 格式、普通阶段 Integration 1211 tests / 64.294 秒、LiveRuntime 串行 231 tests / 208.625 秒、plist 通过。日志 `/tmp/ctl-check2.log`。 |
| `./scripts/build-ios.sh` | 退出 0，五个 scheme 均 BUILD SUCCEEDED（含仅 iOS 编译的 AgentRuntime 改动）。日志 `/tmp/ctl-ios1.log`。 |

验证中发现并修正的问题：(1) 初版把控制调用延后到整轮 Action 结算后执行，使全双工 `task.end` 不再独立于仍在运行的 Action，`fullDuplexTaskEndPersistsAndFolds...` 超时；已改为发射时按序执行。(2) 助手委派目录仍按旧的 Action 登记判断 `task.send`，导致提示词缺少 Writer；已改读 controls。(3) 一个因测试夹具把 `ActionCall` 下标取值导致的崩溃，随断言更新消除。照 BasicSkill 增加 wait 与控制示例后，Photography 提示词预算测试由 38,000 提高到 38,500 字节（实测 38,324）。

未验证：真实模型下新提示词（wait 说明移入 BasicSkill、控制调用改为 Agent 内部控制）的行为；仅有离线解析与单元断言。`Agent.Communication.send` 旧本地路径无生产 Skill 登记，保持原状，另行清理。ConversationHistoryView 展示的目录计数不含控制。修改位于 feat/signal-redesign，未提交。

## 第 21 节：Skill Channel 按互斥占用重新划分的验证

对应需求第 21 节。Skill.json 的 Channel 改为按互斥占用划分：`Query`、`System` 不再使用；窗口/导航、灵动岛、网页、蓝牙设备、模型资源、会话历史、Provider 设置各自独立，`cancelCapture` 使用 `CameraCancel`，Vision 脱离 `Camera`；`Display` 仅保留字幕、回复等待与表情。涉及 ApplicationControl、HistoryQuery、Photography、WebBrowsing 的 Skill.json（revision 递增）、Instructions 中的 Channel 表述、RuntimeLog Channel 颜色及各 README。

| 检查 | 当前源码证据 |
| --- | --- |
| `./scripts/check.sh` | 退出 0：边界、Python 离线回归、严格 Swift 格式、普通阶段 Integration 1212 tests、LiveRuntime 串行 231 tests、plist 通过。日志 `/tmp/check.log`。 |
| 新增测试 | `skillChannelsSeparateIndependentWorkAndKeepExclusiveWorkTogether` 覆盖互斥项共用 Channel、cancelCapture/Vision/Web/Window/Island/History/Provider 独立，及 Channel 总数不超过 16。 |

未验证：真实模型在新 Channel 目录下的编排效果（例如 cancelCapture 与 takePhoto 并行取消倒计时的实际运行行为）、实机行为；仅有离线解析、目录与调度单元断言。修改位于 feat/signal-redesign，未提交。

## 第 22 节：控制函数声明集中与 AssistantChatWorker 拆分的验证

对应需求第 22 节。五个控制的声明与 `AgentControlOperation` 枚举集中在 Support/AgentControls.swift，`AgentControl.operation` 与 `controlTask` 不再使用字符串；`Agent.Task.sendMessage` 的声明从 Support/Communication 并入；执行仍由 Assistant 承担。AssistantChatWorker.swift 由 4051 行拆为主文件（声明、状态、注册）与 Lifecycle、Input、Generation、Feedback、Emission、TaskCommunication、WriterEvents、Status 八个同名 extension 文件，控制执行位于 AssistantControls.swift；成员可见性由 `private` 放宽为模块内部，pbxproj 文件登记与 boundary checker 的读取范围同步更新。

| 检查 | 当前源码证据 |
| --- | --- |
| `./scripts/check.sh` | 退出 0：边界、Python 离线回归、严格 Swift 格式、普通阶段 1212 tests、LiveRuntime 串行 231 tests、plist 通过。日志 `/tmp/check3.log`。 |
| `./scripts/build-ios.sh` | 退出 0，五个 scheme 均 BUILD SUCCEEDED。日志 `/tmp/ios2.log`。 |

测试调整：`controlTask` 的调用改用枚举；未知 operation 已无法表示，原“已移除 operation 返回 forbiddenFunction”的断言和 `task.delegate` 用例随之删除，伪造来源被拒绝的断言保留。

未验证：真实模型与实机行为；本次为文件拆分与类型收紧，不改行为。`AgentTaskSkillState.control` 仍以别名字符串为入参。修改位于 feat/signal-redesign，未提交。

## 第 23 节与 control 两类模型的验证

对应 Signal 需求第 23 节（控制库移入 Assistant、Skill 不再配置控制）与 [Assistant 内部函数标记](../requirements/technical/Assistant-Internal-Function-Tokens.md)。模型可见函数分为 Action（经 Gateway 进入 Actions，含调度与直接 tool 协议）与 control（由拥有者 Agent 执行）。`ControlDestination`（`self`／`peer`）挂在 `ControlRegistration` 与 `ControlCall` 上，`task.send` 为 `peer`，其余四个为 `self`；目录标题行显示 destination。AssistantControls.swift 只保留定义，执行移至 AssistantControlExecution.swift。

实施中发现并修复：第 23 节把控制注册放进 `AssistantContextState.runtimeCapabilities`，但 `AssistantAgent.runtimeCapabilities`（AgentRuntime 覆盖校验与测试所用）仍是 worker 的通用授权，不含控制，导致控制与 Agent 目录从这些入口消失。worker 的 `runtimeCapabilities` 现在转到 `State.runtimeCapabilities`，通用语音／字幕授权改名为 `chatRuntimeCapabilities`。AgentConfiguration 不再容忍已退役的 `controls` 根键。boundary checker 从禁用列表移除 `AssistantControl`。

| 检查 | 当前源码证据 |
| --- | --- |
| `swift build --build-tests` | 退出 0。日志 `build/agent-build.log`。 |
| `./scripts/check.sh` | 退出 0：边界、Python 离线回归、严格 Swift 格式、普通阶段与 LiveRuntime 串行 231 tests 全部通过，无失败项；plist 通过。日志 `build/agent-check.log`。 |
| `./scripts/build-ios.sh` | 退出 0，五个 scheme 均 BUILD SUCCEEDED。日志 `build/agent-ios.log`。 |

新增覆盖：`task.send` 解析为 `peer`、仅 `task.send` 为 `peer`；生成器对 `<task.start/><wait><task.send/></wait>` 产出 `self` control、wait 边界与 `controlInsideWait` 拒绝，且不产生 Action 调用；目录渲染 `Control task.start (self):` 与 `Control task.send (peer):`。

未验证：真实模型在新目录标题下的选用效果（属于 experiments）、实机行为。`task.send` 投递、回执与 Writer 原生工具拆分仍按需求文档待定。修改位于 feat/signal-redesign，未提交。

对照复查后的补充修改：`CallRejection.Kind` 新增 `control`，control 别名的拒绝不再标为 `action`（反馈文案与 round 记录同步）；Agent 目录按是否注册 `peer` control 显示；状态快照 controls 输出 `destination`；AgentConfiguration 的 `controls` 根键拒绝有测试覆盖；MobileHarness、Resources/Agents、Resources/Skills 与 Assistant README 中残留的 `useControls` 描述改为现行设计。复查后 `./scripts/check.sh` 再次退出 0、无失败项（日志 `build/agent-check.log`）；`./scripts/build-ios.sh` 退出 0，五个 scheme 均 BUILD SUCCEEDED（日志 `build/agent-ios.log`）。旧 `send` Action（`Agent.Communication.send`）在生产配置中已无授予，删除方案记录在需求文档待定段，未删除。

## 旧实现清理（不保留兼容）的验证

对应 [Assistant 内部函数标记](../requirements/technical/Assistant-Internal-Function-Tokens.md#旧实现清理不保留兼容)。用户确认不兼容旧实现、数据库可清空。

- 删除旧 `send` Action 整条路径：`AgentCommunicationAdapter`（文件删除）、`modelCommunication`、`deferredCommunications` 与 PendingRound 中的保存、`sendDeclaration`、配置与覆盖校验特例、FunctionCopy 条目、CommunicationContext 中的 `rejection`/`taskDirectory` 模板、`validateCommunication` 要求；checker 拒绝 Skill 绑定 `Agent.Communication.*` 并禁用相关旧标识符。
- 删除未使用 Action：`UI.Notice.showNotice`、`UI.Notice.dismissNotice`、`UI.Light.updateLight`、`UI.Island.update`、`System.Runtime.runtimeInfo`，及只为其存在的 UI 端口与状态。新增 `everyDeclaredActionIsGrantedOrComposedByCode` 防止再出现未授予的声明。
- SQLite 只保留当前版本，其他版本一律清空重建；删除逐版本迁移、旧契约别名查询、`task.cancel` 取消原因回退、旧输入批次重投影与旧来源行模板、旧下载偏好文件搬迁，以及只覆盖这些旧行为的测试。
- BasicSkill revision 59：task.end 不再称为 Action；control 目录标题缩短以保持 photography 提示词预算（38,500 字节）。

| 检查 | 当前源码证据 |
| --- | --- |
| `swift build --build-tests` | 退出 0（子任务日志 `build/sub-build.log`）。 |
| `./scripts/check.sh` | 退出 1：边界、Python 离线回归、严格格式通过；普通阶段 1200 项中仅 `bluetoothUnavailabilityIsPresentedAsStateWithoutFailureToast` 在并行负载下等待超时（`.expired`），单独重跑 0.098 秒通过；LiveRuntime 阶段无失败。日志 `build/agent-check.log`、`build/single.log`。 |

中间运行：首轮 check.sh 暴露测试夹具仍写旧契约名（`task.request`、`agent.task.request`）、两条迁移测试、photography 提示词超预算 88 字节；第二轮只剩一条依赖 `task.cancel` 消息提供取消原因的断言，均已按新契约修正或删除。

未验证：真实模型与实机行为。修改位于 feat/signal-redesign，未提交。

## control 声明资源化与 Writer 到 Assistant 发后即丢的验证

对应 [Assistant 内部函数标记](../requirements/technical/Assistant-Internal-Function-Tokens.md#control-声明放入资源文件已定) 与 [Writer 到 Assistant 的消息](../requirements/technical/Assistant-Internal-Function-Tokens.md#writer-到-assistant-的消息已定)。

- control 声明改由 `Resources/Agents/Assistant/Controls.json` 与 `Controls.zh-Hans.json` 提供，`FunctionCopy` 不再含 `Agent.Task.*`。
- 删除 Writer outbox（`WriterNotifications` 文件与 pbxproj 引用）、Assistant 依赖消息表的恢复与校验、存储中的 outbox/游标 API、列与 `task_observation_cursors` 表；schema 20261121。
- 测试：删除只覆盖重发、游标、恢复跟踪的用例（`completionOutboxRejectsStaleClaimsAndStopsAfterEightFailures`、`taskEventCursorCannotSkipUnconsumedEventsAndIsReceiverScoped`、`consumerConfirmationDoesNotPublishAnEventOrControlItsPublicationQueue`、`assistantRestoresTaskTrackingAndReadsCompletionPublishedWithoutAnyConsumer`、`writerTerminalNotificationCommitRollsBackConflictsAndKeepsIndependentReceipts`）；新增 `completionWritesOnlyWriterExecutionAndRetirementRecordsCleanup`；二十任务用例改为 `writerCompletesTwentyTasksWhileProgressReportsAreDropped`；`WriterResultSink` 不再首投拒收，`WriterTestRequester` 只发送、不预写记录、不补读。

| 检查 | 当前源码证据 |
| --- | --- |
| `swift build --build-tests` | 退出 0（`build/agent-build.log`，Build complete）。 |
| `./scripts/check.sh`、`./scripts/build-ios.sh`、`swift test` | 未执行（按用户要求先只验证编译）。 |

未验证：测试运行、真实模型与实机行为。

## control 提示词归属与 wait 归入 Action 的验证（2026-11-21）

范围见 [Assistant 内部函数标记](../requirements/technical/Assistant-Internal-Function-Tokens.md)。

| 检查 | 结果 |
| --- | --- |
| `python3 scripts/checks/check-modelkit-boundaries.py`（新增：Skill 不得绑定 `Agent.Task.*`、指令不得含 control 标签） | 通过 |
| `swift format lint --strict` | 本次改动文件通过；`AssistantChatWorker.swift` 与 `WriterAgentTests.swift` 的既有告警未改动 |
| `swift test --skip 'LiveRuntimeTests\|NativePresentationTests'` | 1197 项，仅剩 4 个 Writer/数据库测试共 56 个问题；这 4 项在未修改的 HEAD 工作树上同样失败（56 个问题），与本次无关 |
| `swift test --filter 'LiveRuntimeTests\|NativePresentationTests'` | 231 项通过（首轮的 NexArm 夹具缺聆听处理器已修正，相机 Metal 用例首轮偶发失败，重跑通过） |
| `./scripts/build-ios.sh` | BUILD SUCCEEDED（验证脚本改为跳过无 `templates` 的 Controls.json） |

新增测试：`waitIsACatalogActionWhileControlGuidanceFollowsTheOwnerControls`（wait 条目、指南顺序、中文回退、无 Action 与 control 时不渲染）。未执行：真实模型对新提示词选择的评估（属 experiments）与实机验收；`./scripts/check.sh` 未整体运行，其各步骤已分别执行，其中测试因上述既有失败退出非 0。

## Agent v14 信道声明（2026-11-28）

六个打包角色共声明 9 个实际信道，2 个为 send，7 个为 pubSub。同名声明的类型一致。跨 Agent 测试使用与业务协议键不同的传输名称，核对接收元数据中的实际名称。

- 9 项定向 Swift 回归通过，覆盖信道缺失与类型冲突、请求直接应答、发布订阅、取消与超时释放、运行时活动和任务停止通知，以及相机请求返回后 Vision 再调用呈现工具。
- iOS 模拟器的五个 scheme 均构建成功。打包验证通过，包括 105 项 Agent/Skill 资源及中英文应用、UI 和 Live Activity 资源。
- 工程检查脚本在 ModelKit 模块边界检查通过后，因生产模型清单校验失败退出。HEAD 中模型清单已有 kokoro-82m、smart-turn 和 zipformer-kws，检查脚本的预期集合未列出这三项。
- 扩展通信测试包含的 Action 授权清单断言失败，实际未授予条目中含 UI.Island.setPresentation。未执行真实模型推理或物理设备摄像头验收。
- 常规 Swift 测试中，IntegrationTests 的 1311 项有两个测试函数报告失败：上述 Action 授权清单断言，以及语音识别失败后的恢复测试。后者单独重跑时，开始识别失败与结束识别失败两个参数场景均通过。
