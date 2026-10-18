# History Support — 有界预览与共享仓库事务

## 简介

HistoryModule 定义查询/修改能力端口及五项函数绑定；HistoryQueryService 和 HistoryMutationService 基于同一个 ConversationHistoryStore 提供业务实现。

## 上下游关系（一级）

```mermaid
flowchart LR
    Entries[ConversationActions] -->|查询和修改能力| S[History/Support]
    Host[AgentBindings 集成] -.->|仓库与标题计算闭包| S
    S -->|快照与提交| Store[StorageChat 仓库]
    S -->|标题计算| Host
    Catalog[Actions 共用目录组合] -->|构造 HistoryModule| S
    Contracts[FunctionContracts] -.->|目录与失败报告| S
```

## 内部模块关系

```mermaid
flowchart TB
    Module[HistoryModule] --> QueryPort[HistoryQueryCapability]
    Module --> MutationPort[HistoryMutationCapability]
    Query[HistoryQueryService] -.->|实现| QueryPort
    Mutation[HistoryMutationService] -.->|实现| MutationPort
    Query --> Projection[Entry / Turn / Text / Page]
    Query --> Errors[HistoryQueryError]
    Mutation --> Errors
```

## 查询算法与数据约束

list 使用 store.listConversations 的当前会话与归档元数据，顺序沿用按 archivedAt 排序的索引，不加载归档正文。标题和 latestUser 预览各最多 40 UTF-8 字节，turnCount 取输入块数。

read 查找当前或归档会话并调用 `indexedHistory()`，按项目分页。request 项取请求输入与 完整 response 字符串，带请求状态及输入/Task 关联；task 项取 goal 与 reportedSummary/failure 的组合，带实际终态和 Task 身份。user/response 分别限 80/160 UTF-8 字节，total 计算投影项数。

Text 按 Swift Character 逐个累计字节，保留完整字符，并明确提供 truncated。Page 使用 ISO8601 日期、排序键和无斜杠转义的 JSON；整体最多 1800 字节。服务再次验证页范围，错误编码为 missingConversation、resultTooLarge、currentConversation 对应的执行失败代码。

## 修改状态与失败处理

startNew 等待可恢复归档与新 current 创建，返回可选旧会话 ID，并提交根持有的单个标题任务；标题不阻塞新会话。deleteArchived 按ID读取会话，拒绝当前或不存在的会话，在删除前检查取消，再等待仓库原子修改。

summarizeArchived 读取并验证归档会话，执行注入的异步标题计算，检查取消后调用 setTitle。计算或提交失败时尝试保存 nil 标题与最多 1024 字符的错误状态；该记录加入结束后才抛出原始错误。若记录失败，抛 ActionReportedError，包含 title 与 retryState 两条结果，保留主要和次要失败。

服务持有共享 actor 仓库和一个根所有者可取消/加入的标题 worker。自动标题与显式重试共用单个准入槽，溢出明确记录可重试失败；不创建第二个历史仓库或自动重试。取消不能撤销已经完成的持久化；并发与仓库一致性规则由 StorageChat 负责。查询和目录本身不授予历史访问或删除确认。

[History 参数与完成](../README.md) · [StorageChat 设计](../../../Storage/Database/Chat/README.md) · [共享契约](../../Support/Contracts/README.md)

✅ HistoryPresentationAdapter 编译到 ActionBindings，将共享仓库事实转换为 UI 自有值并通过公开呈现接口提交，保留会话/版本围栏。UI 的只读分页由 AgentBindings 经 Gateway/Memory 返回关联结果；纯查询不主动呈现第二次。

## 待实现

- 暂无本目录独立的实现待办；跨模块及实际模型/设备验收见所属模块说明。

## Storage 依赖

✅ 存储访问使用独立的 State、Cache、Database 和 Files 接口；App 注册根实例，消费者通过构造器获得所需能力。存储容器不接管本目录的业务验证、执行和完成语义。

## UI 全量容器化

✅ 应用级 UI 状态由八个子容器统一创建，消费者注入所需 Presenting 接口并提交 UI 自有值，不直接写字段。App 注册并管理同一 UI 根；原业务身份/版本校验、原生完成和基础库依赖边界保持。跨模块连接迁移仍是独立待办。