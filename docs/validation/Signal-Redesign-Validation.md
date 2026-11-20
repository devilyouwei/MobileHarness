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
