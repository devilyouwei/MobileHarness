# Writer 委托记录与 Workspace 解耦验证

本轮验证对象为 [实施计划](../requirements/technical/Writer-Workspace-Separation.md)，不代表此前模型实验或真机版本通过。没有使用真实模型 API；没有修改手机数据库或安装真机。

## 可复现覆盖

- `WriterAgentTests.writerDelegationAndWorkspaceMessagesHaveImmutableScopes`：接纳不创建 workspace；前序与内容消息不可移动；两次委托复用一个 workspace，来源准确；40 条 workspace 消息恰好两页，末页没有游标。
- `DatabaseTableRecordTests.writerEntriesAreUniqueAndRecoveryDoesNotInventWorkspaceMessages`：重复入站幂等、等待信息、补充输入幂等、忙碌拒绝不抢上下文、重启中断、无 workspace 完成和原子 outbox、清日志保留结果。
- `DatabaseTableRecordTests.writerMessageKeysIgnoreRevisionAndDeletedWorkspaceKeepsItsHistory`：消息主键超过 90 亿，传入旧 order 不改变排序；删除留存归属，禁止重新取得租约。
- `DatabaseTableRecordTests.writerSchemaResetRemovesOnlyApprovedFilesAndFailsBeforeChangingDatabase`：旧格式全量重置与文件清理、配置保留、清理失败阻止初始化、当前格式重开保留文件。
- 原有 Writer 原生工具替身回归：创建、选择、先读后选择、选择失败、等待/取消、网络失败、窗口失败、纯库完成、Assistant 消息 FIFO 与收尾。
- `WriterRecordsNativeAcceptance.testDelegationWorkspaceSeparation`：实际 iOS 页面点击、委托详情、workspace 两页、来源跳转、返回保留与末页无加载更多。

## 验证过程与限制

模拟器合成数据导出必须通过 SQLite backup 获取一致快照，不能仅复制 WAL 模式的主数据库文件；导出后再次检查 2 条入口、1 条前序及 40 条 workspace 消息再用于页面验收。

早期定向回归已暴露并修复旧测试将执行状态读取自 workspace 的假设、纯查询完成要求非空 taskID、首次未选择错误缺少恢复条件等问题。格式检查失败已逐项处理。早期 iOS 主应用编译成功后，资源校验发现旧 Skills/README.md 的增量打包缓存；最终主应用重新打包后资源校验已通过。

- `./scripts/check.sh`：边界、Python、格式及资源静态检查通过。IntegrationTests 首次并发运行有 7 个用例失败（13 个 issue），故完整脚本不能记为全绿。7 个用例随后串行复跑全部通过（50.615 秒）；其中 Writer 20 委托通知拒绝/恢复用例耗时 49.209 秒，首次触发 60 秒截止。其他失败涉及 Assistant、相机与 tracking 时序。没有将这些首次失败从证据中抹去。
- 新增存储重置、入口幂等/恢复、大主键/删除留存与消息归属回归均通过。
- `LiveRuntimeTests`：227 个通过（240.406 秒）。
- `NativePresentationTests`：前两个相机用例通过，`cameraNativeMetalDrawStopAndLayerHandoff` 只有启动记录、没有完成记录；该相机套件不能记为通过，也不是 Writer 页面验收结果。
- 过程日志：`/tmp/writer-separation-check4.log`、`/tmp/writer-separation-rerun.log`。日志为本机临时证据，不作为仓库长期文件链接。

首次并发失败、串行通过的用例：
`agentProtocolFailureProjectsShortToastFullDetailAndCorrelation`、`speechRecognitionSnapshotToastPreservesDetailedRecordAndInput`、`cameraFirstFramePendingDoesNotCaptureOrStartReact`、`executionFailureObservationIsIndependentAndBounded`、`assistantExecutesRobotActionWithoutDelegation`、`slowTrackingDispatchExecutesOnlyTheNewestPendingTarget`、`writerAcceptsTwentyTasksWithAllUserNotificationsRejectedThenRestoresOnlyDelivery`。

`./scripts/build-ios.sh` 最终运行退出码 0：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个方案全部 BUILD SUCCEEDED，最终应用资源与 Live Activity 校验通过。日志 `/tmp/writer-separation-ios-final.log`。

## 原生页面验收阻塞

使用独立 iPhone 18 Pro / iOS 27 模拟器 `A05ADC47-EDE4-4964-A53F-99F1926917BD`，安装最终构建，导入 2 条入口、1 条前序和 40 条 workspace 消息。最终快照导出专项测试通过（2.297 秒），只读 SQL 再次确认 `(NULL, 3)`（含 2 个入口）和 `(1, 40)`。测试导出使用 SQLite backup 并转为 DELETE journal 的独立快照，不依赖 WAL 边车文件。

`WriterRecordsNativeAcceptance.testDelegationWorkspaceSeparation` 已编译并启动实际应用，但应用停留在“正在准备”，XCTest 连续三次无法获取 `app.settings` 的 accessibility 查询结果，尚未进入 Writer 页面。屏幕可见设置按钮；这不能证明按钮可交互。线程 sample 也未返回，无法据此确定是应用启动还是模拟器/自动化连接问题。运行超过 5 分钟仍无进展后停止本轮专用测试进程并关闭该独立模拟器；没有关闭其他模拟器或修改手机数据。

本轮原生页面验收**未通过/未完成**，不把分页仓库测试当作原生交互通过。原生测试代码保留，可用 `WRITER_UI_ONLY_TEST=testDelegationWorkspaceSeparation` 重跑。原生过程日志 `/tmp/writer-separation-native3.log`，未完成结果包 `/tmp/mobileharness-writer-ui.yIgsFO/WriterUI.xcresult`，启动画面 `/tmp/writer-separation-current.png`；这些是本机临时诊断证据。快照回归日志 `/tmp/writer-separation-seed5.log`。

后续验收仍需：排除启动/自动化阻塞后完成委托页面、40 条末页、来源跳转及返回保留的实际点击；原相机 NativePresentationTests 的未完成项也未被本轮解决。需求保留在 requirements，不提前归档。真机安装和真实模型验收未执行。

最终定向 Swift 格式检查与 `git diff --check` 通过。

## 2026-11-08 真机前序链路与分域回归

再次读取 iPhone 的 SQLite 主库与 WAL 并生成离线快照，完整性检查通过，外键违规为零。首个委托的前序消息 18 和 20 的 workspace_id 均为空，分别调用 projects 与 edit(index.html)。两轮记录的 system 内容散列相同，原版以统一工具目录处理。此处是旧真机版本的执行证据。

本机回归使用真实 SQLite、Writer、Gateway、Artifacts 和模型替身。查询以关键词分页，结果不加载文件正文。创建在首次 edit 之前准备目录和窗口。已有作品通过 enter 或 open 接入独立控制域。数据库分别保存前序与工作区消息，查看保留原文件和草稿状态。窗口验证使用本机 WebKit 与原生 WindowState，场景恢复和最小化测试与真机验收分开。

`scripts/check.sh` 退出 0，主集成 1103 项和 LiveRuntimeTests 227 项通过。NativePresentationTests 在相机测试开始后没有套件完成记录。最后一次窗口中断调整后，定向检查再次通过 SQLite 搜索分页、Writer 九种分域场景、原生 WebKit 同窗预览与最小化恢复、场景隐藏和动画打断两个变体。

`scripts/build-ios.sh` 的四个模拟器目标通过。最终窗口源码再次构建 MobileHarnessSimulator 通过。本轮新实现尚未在真机复验。

### 真机覆盖安装

2026-11-08，MobileHarness 真机 Debug 构建 0.1.0（2026110808）通过签名、Agent/Skill 资源与 Live Activity 校验。通过 devicectl 覆盖安装到 iPhone 17 Pro，安装回执 sequence 6368，设备应用列表确认构建号 2026110808，启动请求成功。本次验证覆盖安装与启动，Writer 的真实模型委托和入口窗口交互尚未复验。

## 2026-11-09 Writer 请求详情导航

前序和 Workspace 请求共用请求详情。已删除委托回链及其专用目的地，UI 回归分别检查两个入口的请求详情与返回行为。iOS XCTest 源码类型检查通过。真机应用产物不含委托回链标识，保留前序请求和工具来源标识。独立模拟器启动停在系统数据迁移，点击用例本轮未运行。

真机 Debug 构建 0.1.0（2026110809）通过签名、应用资源与 Live Activity 校验。devicectl 覆盖安装到 iPhone 17 Pro，安装回执 sequence 6376。设备确认构建号并成功启动。此处记录安装和启动，未执行真机页面点击验收。

`scripts/build-ios.sh` 四个模拟器目标均通过。首轮完整检查在模拟器初始化和构建并行时出现多项超时。停掉独立模拟器并等待构建后复跑，1103 项主集成测试中仅 slowTrackingDispatchExecutesOnlyTheNewestPendingTarget 的目标值断言失败。该用例使用同一测试产物单独重跑通过。227 项 LiveRuntimeTests 通过。NativePresentationTests 在相机测试开始后没有套件完成记录。格式、边界、Python、plist 和差异检查通过。

## 2026-11-09 锁屏后预览恢复

真机 SQLite 与 WAL 的只读快照通过完整性与外键检查。00:10:55 接纳的委托 108 在 00:14:03 完成，task_1 有已发布令牌与一个索引文件，委托无失败。截屏的错误链为 Actions 前台恢复中的 WebPageError.timedOut。代码核对确认旧恢复会把任一作品窗口的呈现失败上抛给应用场景 worker。

macOS 原生 WebKit 定向测试通过。一个项目的预览槽因符号链接拒绝时，原内容保留，另一个项目仍恢复。解除故障后可加载最新入口并清除窗口诊断。另验证了再次隐藏会取消并加入等待开窗回执的恢复任务，以及场景隐藏和动画打断两个首次呈现变体。故障注入覆盖呈现失败隔离，未模拟 iPhone 的实际 WebKit 超时。

修复版 0.1.0（2026110901）签名、Agent/Skill 与 Live Activity 校验通过，覆盖安装到 iPhone 17 Pro。安装回执 sequence 6384，设备确认构建号并成功启动。未执行真机锁屏操作。

`scripts/check.sh` 退出 0。1103 项主集成测试与 228 项 LiveRuntimeTests 通过，包含预览失败隔离和隐藏取消回归。NativePresentationTests 在相机测试开始后没有套件完成记录。`scripts/build-ios.sh` 四个模拟器目标均构建成功，最终真机构建也通过。格式与差异检查通过。
