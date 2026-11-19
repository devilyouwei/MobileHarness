# Tests 分层整理验证

2026-11-19。对应 [实施计划](../completed/Tests-Optimization-Plan.md)。保留八个模块目录与既有 SwiftPM target，按 Unit Tests、Integration Tests、UI Tests 描述测试边界；未新增目录、依赖或生产接口。

## 结构与行为

| 调整 | 覆盖承接与边界 |
| --- | --- |
| 蓝牙混合文件拆分 | 原 96 个声明全部保留：7 个 BLE 机制单元留 PlatformKit；14 个规划/连接策略单元归 Actions/NexArmConnectionPolicyTests；2 个 UI 状态单元归原 BluetoothConnectionStateTests；73 个工作流/原生状态协作与 fixture 归 Actions/NexArmBluetoothIntegrationTests。原 LiveRuntimeTests 隔离不变。 |
| 生成观察值拆分 | 四个纯转换用例归 GenerationObservationTests；实际请求、执行和 journal 的 compactRound 用例及其他轮次回归留 GenerationRoundTests。 |
| UI 自动化命名 | WriterRecordsNativeAcceptance → WriterRecordsUITests；两个原 XCTest 方法不变，脚本过滤类名、源路径、Package 和 Xcode 导航同步。 |
| 设置事务合并 | settingsFacadeFailureKeepsConfirmedLabelAndReconcilesOnExplicitRestore 与 settingsFacadeCommitsOnlyAcknowledgedInjectedSave → settingsFacadeCommitsOnlyAcknowledgedSaveAndReconcilesFailure(fails:) 的 true/false 两项；确认标签、恢复值与恢复次数断言保留。 |
| 平台限制 | 普通用例用函数级 @available，受限平台报告跳过；显式模型验收在平台不支持时抛 unavailable。CoreAI 编译条件未满足时显式记录失败。 |
| 对照输入回归 | 增加 decisionParityRequiresSelectedReferenceCases 和 tokenizerParityRequiresReferenceRows，合计九个参数场景；只用内存夹具，不加载模型。选择为空、未知模型、缺少参考项和非法 kind 在加载前拒绝。 |
| 分层导航 | 根及八模块 README 说明每组文件层级与边界；所属能力 README 明确拆分后的所有权。Contract/Regression/Smoke/Performance/Acceptance 和环境不另建目录层。 |

蓝牙提取的 23 个独立测试体经忽略格式空白的逐函数对照，内容保持；UI 自动化源码除类名外逐字符一致。工作流的内部 fixture 保留私有，不引入跨模块测试辅助库。

AgentTaskSkill、GenerationRound、WriterAgent、蓝牙工作流和历史呈现各自保护授权/Skill、轮次结算、文件提交/通知、连接/接管和分页/证据等不变量；保留相似但边界独立的失败/取消回归。此次只合并已确认同路径的两项设置事务测试，不通过删减不变量压缩数量。

## 静态核对

- Swift 文件 176 → 179，所有文件均登记在 testSources、无漏挂/重复/不存在路径，并纳入模块索引。
- @Test 声明 2101 → 2102：两项设置事务合为一项参数化声明，新增两项输入回归，其余原函数名称保留。声明数不是参数化执行数或通过数。
- `swift test list --skip-build` 返回 0，发现 2099 项；与 2102 个源码声明的差异仅为 iOS 条件下的 AgentContainer 身份、halo 停止、原生触觉三项。日志 /tmp/mh-tests-layer-discovery.log。
- XCTest 两个原 UI 方法保留；条件编译宿主、模型/设备开关与独立入口不计为默认已执行验收。
- 当前 Tests 本地文档链接、Xcode plist 与 simulator 脚本语法通过；历史报告的旧路径和统计保留当时含义。

## 执行证据

环境：macOS 27.2.1、arm64、Xcode 27.2（27B52）、Swift 6.4.2。脚本自动选择完整 Xcode 工具链；没有更改系统 xcode-select。

| 检查 | 结果与日志 |
| --- | --- |
| 定向 Swift 回归 | 通过。覆盖新输入校验、设置事务、观察值、BLE ACK、规划和 UI 状态；日志 /tmp/mh-tests-layer-targeted.log。 |
| ./scripts/check.sh | 返回 0。边界、8 项 Python 工程工具回归、严格格式、Swift 普通与串行阶段、五个项目/plist 检查均通过；日志 /tmp/mh-tests-layer-check.log。 |
| ./scripts/build-ios.sh | 返回 0。MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAppleLLM 五个 Simulator scheme 全部构建成功；最终 Agent/Skill、Live Activity 和中英文本地化资源校验通过。日志 /tmp/mh-tests-layer-ios.log。 |
| XCTest UI 点击、独立生产装配/WebKit 宿主、真实模型、物理设备、实验矩阵 | 本次未执行；源码改名/编译和替身测试不作为这些验收通过。 |

完整检查和 Simulator 构建串行运行。定向构建出现仓库既有的 imgs 未显式排除及部分宏展开无用 try 等警告；本次不扩大到无关工程清理。

Swift 普通阶段中，IntegrationTests 为 1182 项、UITests 为 215 项、AppWorkflowTests 为 197 项；串行 LiveRuntimeTests 为 231 项（206.785 秒），其余 target 汇总也通过。上述为运行器汇总，保留显式关闭/平台条件的跳过，不表示真实模型或设备已执行。
