# Action 多轨道调度与 wait 验证

日期：2026-11-21。范围：[需求](../requirements/technical/Action-Multi-Channel-Wait.md) 的实现——Skill 注册的 `wait`、自闭 `<wait time="秒"/>` 主轨道延时、Basic Interaction 教学迁移及共享目录清理。结果来自混合工作区（含其他未提交改动），未做干净基线对照。

## 自动化证据

- 解析/生成：秒与小数（`1.5`、`2`、`0.001`）解析为毫秒；`<wait/>`、`0`、负数、超过 60 秒、非数字、科学计数、`.5`、空值、多余属性均作为 `invalidParameters` 调用拒绝；单次生成累计超过 120 秒得到 `limitExceeded` 拒绝；未注册 wait 的 Agent 对成对标签和延时均得到 `unknownCapability` 拒绝；`application-control` 不带 wait，Basic Interaction 带 wait 且目录中没有 `wait` 别名。
- 调度：延时在较早 Action 仍运行时返回，不等待其完成，之后的 Action 照常入队；任务取消使延时以取消结束；超出每任务累计上限或非正值得到 `pauseLimitExceeded`。
- 教学：从打包资源读取 Basic Interaction 的全部 XML 示例，用生产目录逐字符解析；嵌套、延时及作用域后延时示例可解析且无拒绝；中英文均含 32 个 wait 上限与“优先整秒”说明；共享目录不再暴露 wait 条目。
- 旧语法回归：以 `<wait x='1'>` 替代原 `<wait/>` 作为“解析失败终止生成”的夹具；成对标签的语法限制测试保持不变。

## 命令与结果

- `swift build --build-tests`：通过。
- `swift format lint --strict --recursive MobileHarness Macros Tests Package.swift`：通过（含对两个源文件执行 `swift format --in-place`）。
- `python3 scripts/checks/check-modelkit-boundaries.py` 与 `python3 -m unittest discover -s scripts/checks -p 'test_*.py'`：通过（8 项）。
- `./scripts/check.sh`：退出 1。非运行时阶段 1203 项测试中，仅 `completionWritesOnlyWriterExecutionAndRetirementRecordsCleanup`（`DatabaseTableRecordTests`）与 `writerBackgroundRoleUsesDirectGatewayAndPublishesActualArtifact(mode: 7)`（`WriterAgentTests`）失败，共 3 个 issue；运行时阶段 231 项通过。两项失败位于 Writer 存储/后台角色，不涉及 wait，但未在干净基线复现，不据此归因。
- `scripts/resources/verify-app-agent-resources.py` 需要已构建的 App 路径参数，本次未执行；其 scheduling 绑定适配只做了源码修改。

- `./scripts/build-ios.sh`：退出 0，输出 `BUILD SUCCEEDED`（日志 `/tmp/mh-wait-ios.log`）。

## 未执行

真实模型是否按新教学生成 `<wait>` 与 `<wait time/>`，以及真机语音/表情时序体验，均未执行，不由 parser/scheduler 单元测试代替。
