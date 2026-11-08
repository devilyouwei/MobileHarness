# Skill 发现与能力拒绝教学验证

2026-11-08。对应[实施计划](../requirements/technical/Skill-Discovery-Before-Denial.md)。

## 首轮改动与证据边界（revision 47 / 6）

BasicSkill revision 47 在常驻指令中区分“当前已加载函数”与 AVAILABLE SKILLS 可加载能力；按用户意图匹配公开描述，在认定不支持前检查 Skill/Agent 目录。单次访问加载、新持续目标携带 skills 启动、已加载不重载、普通知识问答直接回答，以及真实限制/失败仍如实报告。浏览 B 站的加载示例在默认请求即可看到。WebBrowsing revision 6 的公开描述说明网站名/URL 访问及未提供的交互能力。

新增确定性测试从实际打包示例解析 loadSkills、提交 Skill 状态、验证下一轮 Web.browse 和旧目录仍不可调用的边界。新增六个真实模型评估场景；浏览执行端点仅返回明确标注的合成文本并更新合成 ui.web，不访问网站、不伪造媒体。

## 已执行

- 三个改动 JSON 可解析；新增加载示例为合法 XML，skills 为正确 JSON 数组。
- 两个改动 Swift 测试文件的 `swift format lint --strict` 通过。
- `git diff --check` 通过。
- `./scripts/check.sh` 首次失败：并行存储变更期间，WriterWorkspaceRow.swift 尚未进入当时读取到的源码归属声明。日志：`/tmp/skill-discovery-check.log`。
- `./scripts/check.sh` 复查通过模块边界检查，但在现有 Writer/Storage/UI 等文件的全仓格式检查失败，未进入自动化测试；未修改这些无关文件。日志：`/tmp/skill-discovery-check-retry.log`。
- 定向 Swift 测试未执行：IntegrationTests 编译被 WriterModelEvaluationTests.swift 中 WriterWorkspaceRecord 已不存在的 failure/delegateID，以及 SeededWriterWorkspace 类型不匹配阻断。本次新测试不能标记通过。日志：`/tmp/skill-discovery-focused.log`。
- `./scripts/build-ios.sh` 失败：当次构建计划仍引用缺失的 WriterWorkspaces/WriterTaskRow.swift，MobileHarnessSimulator 未完成，后续三个目标未运行。日志：`/tmp/skill-discovery-ios.log`。

## 待验证

工作区存储/Writer 并行变更稳定后重跑定向测试（含 assistantInstructionBudgetsKeepCatalogAndSafetyRules）、全仓检查和四目标 iOS 构建，再运行已有 Qwen 评估入口的六个 skill-discovery 场景。此次未启动真实模型调用：评估所需 IntegrationTests 无法编译，不能使用旧测试二进制冒充当前源码结果。

没有真实 B 站访问、原生 WebKit、手机安装或物理设备验收；不能由资源语法检查推断模型遵循率或网页可访问性。本次没有模型前后对照数据，不宣称用户现象已在真实模型中复现或消除。

## 通用规则修订（revision 48 / 7）

根据用户纠正，BasicSkill 移除站点、摄影、历史查询的业务示例和业务 Skill ID；能力不足时必须先查 AVAILABLE SKILLS 并自行加载匹配项，收到成功反馈后才能使用。只有没有相关 Skill 或可委托 Agent 时，才说明能力未提供；加载/执行失败保留具体原因。单次加载、Task 启动携带 Skill、同行委托的既有边界保留。WebBrowsing description 去掉特定站点示例。

确定性回归动态枚举全部五个非基础 Skill；生命周期例子只保留通用目标，单项/多项 Task 初始加载使用测试侧 fixture。静态检查确认 BasicSkill 不含业务 Skill ID/浏览摄影示例，资源 JSON 合法。改动测试文件格式检查已通过。

本轮定向测试先暴露一条要求保留摄影 releaseSkills 示例的旧断言，删除该过时断言后六项全部通过，包含所有五个非基础 Skill 的发现/加载。日志：`/tmp/skill-discovery-generic-focused.log`、`/tmp/skill-discovery-generic-focused-retry.log`。revision 48 的基础/摄影提示分别为 18,769 / 32,662 字节，均在既有预算内。

`check.sh` 的边界、Python、格式及编译检查通过；IntegrationTests 的 1101 项测试有 6 项失败，属于工作区现有存储/Writer 变更，包括 workspace_files 删除查询引用不存在的 workspace_id。原生阶段等待共享 SwiftPM 锁超过九分钟仍未启动，终止了本任务的等待进程，没有中断其他任务；该阶段未执行，不能标记通过。日志：`/tmp/skill-discovery-generic-check.log`。四个 iOS Simulator 构建目标全部通过（此轮构建开始于 revision 48），日志：`/tmp/skill-discovery-generic-ios.log`。上一轮失败记录保留，不覆盖。

## 通用规则实模复验与限制（revision 48 / 49）

Qwen3.8 Max 使用真实 Assistant/Gateway 与合成设备/网页执行反馈。revision 48 的七场景通过 5/7：网页冷启动、已有浏览能力、失败不重试与普通问答通过；相机已正确加载，但夹带英文解释，违反控制轮独占；机械臂请求错误使用表情而没有加载动作 Skill。

根据这两个失败，revision 49 只补强通用规则：必须匹配用户所需的实际效果，不得用其他已加载动作替代；加载轮只输出一个控制 Action，不带解释。没有加入业务示例或特定业务分支。

revision 49 复验四场景通过 3/4：相机冷启动修正为单独加载后执行；网页冷启动、普通知识问答通过；“点一次头”仍返回 express(smile)，没有加载 robot-interaction。这是尚未解决的模型泛化失败，不能据此宣称所有能力发现已可靠。两轮选取不同场景，不将总通过率直接作为提升幅度。

第二轮在共享构建锁持续占用时，先逐字节核对已编译 Agents bundle 的 BasicSkill 与 WebBrowsing 资源等于最新源码，再通过已有评估脚本的 skip-build 路径直接使用已知测试二进制位置，省去会等锁的路径查询；未改生产代码或共享 bundle。两轮 sourceUnchanged 均为 true。模型响应、调用、原始报告路径与 hash 摘录见[测量记录](../measurements/skill-discovery-2026-11-08.json)。

revision 49 的四目标资源重打包、原生阶段、真实设备/网站验收及剩余模型泛化失败均未作为通过项。本需求保留未归档，不把通用教学改动等同于对模型行为的确定性保证。
