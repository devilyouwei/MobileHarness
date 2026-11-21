# Writer 委托生命周期收敛

## 目标

一次委托（agent message）只产生一次完成并只发布一次回报；委托状态只有两层、互不重复；失败路径不会永久占用 Writer。Writer 继续只依赖通用 AgentTask 协议与基础模块，不引入对 Assistant 等其他 Agent 的依赖。pub/sub 不确认：回报丢失不重发。同一 workspace 可由多次委托多次完成，限制只针对同一委托。

## 状态分层

| 层 | 归属 | 表达 | 取值 |
| --- | --- | --- | --- |
| Agent state | 所有 Agent 共有（`AgentLifecycle`，内存） | Writer 进程是否在运行 | registered / running / paused / stopped / failed |
| Task state | 单个委托（`writer_executions.task_state`，持久化） | 委托自身的生命周期 | running / cancelling / completed / failed / cancelled / interrupted |

两层互不表达对方：

- 委托不能被单独暂停，只能取消或自然结束。`pause()` 是 Agent 级动作，暂停期间委托的 task state 仍为 `running`，暂停只由 Agent state 体现，不持久化到委托。
- “等待补充输入”不是状态：`running` 且 `pending_question_id` 非空即等待用户。
- 终态只写一次，不再在别处复制。

Task state 取值与 `AgentTaskRegistry.State` 对齐：`cancelling` 即请求方已提交停止请求、终态尚未写入；`completed` 对应共享枚举的 `succeeded`（存储层不依赖 Agents，只存同名字符串，由 `WriterAgent` 在边界映射，对外 `status` 与 UI 沿用 completed）。`requested`（尚无执行行）由存储层派生；`accepted` 与 `running` 在 Writer 内无区别，不使用。

### cancelled 与 interrupted

两者终止原因不同，不合并：

| | cancelled | interrupted |
| --- | --- | --- |
| 发起方 | 委托方的停止请求，或模型明确给出的 `cancelled` 结果 | 无人请求：Agent 停止、委托超时、admission 时 Agent 不在运行、进程重启恢复 |
| 订阅方处理 | 预期结果，不重试 | 可重新委托，副作用可能只完成一部分 |

对外完成信号 `AgentTaskSignal.Status` 只有 succeeded / failed / cancelled，`interrupted` 在回报中折为 `failed` 并在失败原因中说明；是否在共享信号契约中新增 `interrupted` 会影响所有 Agent，不属于本次变更。

## 存储模型（`writer_executions`）

删除 `run_state`、`terminal_state`，改为：

| 列 | 含义 | 取值 |
| --- | --- | --- |
| `task_state` | Task state | running / cancelling / completed / failed / cancelled / interrupted |
| `completion_recorded` | 完成已落库（只用于“完成一次”） | 0 / 1 |
| `retirement` | 执行权限退役，独立于 task state | `pending`（执行中或待退役）/ `done` / `failed`（退役失败）/ `none`（入口忙被拒绝，从未执行） |

- 单 Writer 唯一索引：`retirement IN ('pending','failed')`，即委托在退役完成前持续占位；退役失败持续占位直至重启恢复。
- 入口忙被拒绝的委托：`task_state='failed'`，`retirement='none'`，失败码 `writer.busy`，不进入历史与占位。
- 退役结果只在 `retirement` 与 `failure_json`（stage=cleanup）记录，不再占用 task state。

### 完成一次

`completeRequest` 仅在 `task_state` 为 `running`、`cancelling`，或 `interrupted` 且 `completion_recorded=0` 时接受（重启恢复只落库、不发回报，补发的第一次完成是合法的第一次）；写入终态并置 `completion_recorded=1`，其余情形抛 `conflict`。检查与写入在同一事务内。

### 停止请求

`acceptWriterCancellation` 仅在 `task_state='running'` 时置为 `cancelling`，并记录取消原因标记；其余状态抛 `conflict`。

### 恢复

重启时：`running`/`cancelling` 转为 `interrupted` 并写入完成时间与失败原因（`completion_recorded` 保持 0）；所有 `pending`/`failed` 的 `retirement` 转为 `done`（授权不跨进程，无物可释放），因此 `retirement` 失败不再永久占位。

### Agent 路径

`WriterAgent.report(status:)` 把 `retireRequest` 失败作为交付失败记录，不再向外抛出；该方法只在终态尚未持久化时抛错，外层 catch 的失败回报重试因此只发生在持久化之前。完成之后的重复尝试由存储层 `conflict` 拦住。`updateRequestPhase` 不再存在：暂停与等待输入不属于持久化的委托状态。

### 对外与 UI

对外 `status`：requested / running / completed / failed / cancelled / interrupted（`cancelling` 对外为 `running`）。`WriterRequestRecord` 暴露 `taskState` 与 `retirement`；UI 展示状态由它们与 `waiting` 派生：`cancelling` 显示 Finishing/Cancelling，`running` 且有待答问题显示 Waiting for input，`retirement` 为 `failed` 显示 Cleanup failed，其余沿用 `status`。

## 受影响文件

- `MobileHarness/Storage/Database/SQLiteSchema.swift`（schema 版本，存量数据不迁移，按现有规则重建）。
- `MobileHarness/Storage/Database/WriterMessages/`：`SQLiteWriterExecutionRepository.swift`（表与索引）、`SQLiteWriterExecutions.swift`、`SQLiteWriterCompletion.swift`、`SQLiteWriterHistory.swift`、`WriterExecutionRepository.swift`（移除 `updateRequestPhase`）、`WriterRequestRecord.swift`及 README；`WriterWorkspaces/SQLiteWorkspaceRepository.swift`（删除保护）。
- `MobileHarness/Agents/Writer/WriterAgent.swift`、`State/WriterRecords.swift`、`README.md`；`MobileHarness/UI/Settings/WriterRecordsView.swift`；`MobileHarness/Storage/Database/README.md`、`MobileHarness/README.md` 中相关描述。
- 测试：`Tests/Storage/Database/DatabaseTableRecordTests.swift`、`WorkspaceRepositoryTests.swift`、`Tests/Agents/Writer/WriterAgentTests.swift`。

## 验收

同一委托二次完成冲突；恢复后的 `interrupted` 可首次完成一次；退役失败与处于 `cancelling` 的委托经重启恢复不再占位；退役后 `retirement` 为 `done`；暂停不改变委托的 task state；Writer 相关 Swift 测试与工程检查通过。
