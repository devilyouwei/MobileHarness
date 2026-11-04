# Task Repository

## Responsibility and implementation

TaskRepository.swift defines async creation/completion and an opaque namespace. MemoryTaskRepository stores bounded ephemeral business records (8192 default, explicit capacity constructor), uses independent local primary keys and never claims restart durability. SQLiteTaskRepository.swift owns tasks schema, committed AUTOINCREMENT allocation and interruption/completion SQL; it compiles only in StorageSQLite.

## Direct relationships

StorageTasks depends only on Storage. Chat/Agents consume the protocol; App constructs/injects a backend family. No model decisions, Skill transitions, native effects or inferred execution success belong here.

## Lifecycle and failure contracts

Running creation commits before activation; terminal update never reopens a completed record. Parent references validate within the same backend. Binding failure is explicitly finished by the Agent, not silently removed. Source/compression projections belong to Chat and its atomic checkpoint contract.

[Storage](../../README.md)

Task creation/terminal updates use a private GRDB record. Creation commits running and returns the key before activation. Runtime changes remain in memory, terminal transitions flush status/summary/failure. No Task JSON snapshots or implicit ORM writes.

## Storage 容器关系

本目录的领域端口由 DatabaseStorage 发布；SQL 适配器统一归 Database/SQLite 编译，业务调用方不导入 SQLite 后端。

DelegatedTaskRecord 关联稳定任务身份、Agent、Writer 对话、原始目标、项目、最新执行及展示阶段；DelegatedRunRecord 对应普通 tasks 执行行并保留每次目标、输入、来源和取消原因。beginDelegation 原子选择/创建对话和运行记录，最新运行未终止时拒绝再次接纳。bindProject 检查 task/run/Agent 并禁止重绑定；查询按 Agent 隔离、每页1...50项。来源对话使用 ON DELETE SET NULL，任务拥有的对话不随来源删除。旧执行行仍只允许终态关闭，不重新打开；续作创建新执行行。不导入旧版任务或消息，不存在旧任务只读分支。

workspaceReady 区分已绑定预留项目与初始化完成项目。bindProject(ready:false) 预留同一项目身份；ready:true 只能将就绪状态推进，不能回退或重绑定。workspaceReady 直接属于当前建表契约。

## Durable terminal notifications

TaskNotification 是不解释业务载荷的中立持久值，关联 Agent、runID、eventID、不可变字节及独立的送达/退休确认。completeDelegatedRun 在一次事务中提交执行终态与通知，重复同一通知幂等、冲突拒绝；身份通过 delegated_runs 的 Agent 归属校验。delegatedRun 提供单次执行的可信状态，业务方无需依赖异步通知视图。

待送达与待退休查询各按运行身份分页（每页1...32）；两种确认及失败证据分别保存。通知存储随任务持久保留，不以待送达条数限制新任务。Storage 不负责传输、重试、消息协议或模型工作流；这些由消费 Agent 拥有。
