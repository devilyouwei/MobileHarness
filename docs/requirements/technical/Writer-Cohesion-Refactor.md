# Writer 内聚与 Assistant 解耦重构

用户确认：开发阶段不保留旧协议、旧数据与兼容代码，开发 SQLite 可删除重建。Writer 对外只暴露通用任务通信协议、根装配接口和 Settings 读模型，内部按职责拆分文件。

## 已完成

### 通用任务协议（Support/Communication）

- `WriterDelegationEvent` → `AgentTaskEvent`（版本重置为 1，不解码旧版本），`WriterFailureDiagnostic` → `AgentTaskFailure`，`WriterContextFact` → `AgentTaskFact`。
- `AgentTaskContent.writerEvent` → `event`；`AgentTaskView.writerEvent / writerFacts / retainWriterFacts` → `event / facts / retainFacts`。
- 删除事件内冗余的 `delegateID`（恒等于 `scope.id`）与 `workspaceID`；工作区引用改由 `AgentTaskContent.artifactID` 携带，正文不再拼接 `Workspace workspace_N` 前缀。
- 新增 `AgentTaskMessaging.isPeer(_:)` 作为“可回报的同伴执行者”唯一清单。
- 删除 `writer.completion`、`agent.taskMessage`、`task.request` 旧契约读取：Assistant 接收、Writer 通知与 Storage 查询只认 `agent.task.response`。

### Assistant 去 Writer 语义

- 所有 `.writer` 分支改为 `AgentTaskMessaging.isPeer`；回报来源必须等于 `scope.executor`。
- `WriterNotice` 等改名为 `PeerTaskNotice` 系列；提示模板改为 `taskQuestion / taskEventsHeading / taskEvent / taskNotice`，以 agent ID 渲染，不写死 `Writer。`。
- 删除输入批次对 Writer 的特殊来源标签及 `legacySourcePattern` 中的 `Writer` 分支；同伴消息统一呈现为 `Agent (writer)`。

### 停止协议

删除 Writer 对“取消当前创作”固定短语的匹配，以及 BasicSkill 要求 Assistant 发送该短语的教学。停止意图统一由 Writer 收件意图分类（followUp / stop / newWork）判断。

### Writer 内部

| 文件 | 职责 |
| --- | --- |
| `WriterAgent.swift` | 角色入口、收件、准入、执行、工具端口与回报队列 |
| `WriterWorkflow.swift` | 模型-工具循环、收件意图、`WriterBudget` 预算常量 |
| `WriterTools.swift`（新增） | 工具端口、工具结果、控制域、本地工具声明、`WriterToolGroup` 工具分组 |
| `WriterContainer.swift` | 根生命周期与存储装配 |
| `WriterRecords.swift`（新增） | Settings 读模型，独立类型，依赖全部 private |
| `WriterRequestNaming.swift`（新增） | 请求命名 |

- 修订合并去重为单一 `absorb`；`WriterWorkflow` 合并为单一初始化器；文件变更/边界/独占工具集合与字节预算统一命名。
- 删除旧中文阶段名映射、诊断中“历史”字符串判断；测试改用规范英文阶段名。
- 删除 `WriterContainer.artifacts / bindArtifacts` 透传，设置页经 `AgentContainer.writerArtifacts` 取得宿主导出端口。
- 预检所有者 ID 由 Storage 的 `WriterPreflightOwner.id(_:)` 提供，读取统一走 `WriterHistoryStore.preflightPreviews`。

## 未完成

- `WriterAgent.swift` 仍约 1340 行。计划中的 `WriterAgent+Tools.swift / +Reports.swift` 扩展拆分未执行：Writer 与 Assistant 同属 `Agents` 编译目标，跨文件扩展需要把约二十个 private 状态放宽为 internal，会让 Assistant 可直接访问 Writer 状态，反而削弱解耦。替代方案是把回报队列抽成独立 `WriterReporter` 类型、把按 delegateID 分散的字典聚合为 `WriterDelegation` 状态，二者需要单独设计与回归。
- Assistant 自身的旧批次历史恢复（`LegacyBatch` 文本、`restoreLegacyBatchInput`、`legacySourcePattern`）属于 Assistant 输入历史范围，未在本次处理。

## 验证

- `swift format lint --strict` 与 `scripts/checks` 边界检查：通过。
- `swift test --skip 'LiveRuntimeTests|NativePresentationTests'`：全部通过（主套件 1182 项）。
- `swift test --filter 'LiveRuntimeTests|NativePresentationTests'`：231 项通过。
- `./scripts/build-ios.sh`：BUILD SUCCEEDED。
- 未执行：真实模型与真机验收。
