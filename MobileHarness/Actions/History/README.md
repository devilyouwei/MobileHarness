# History — 业务函数与执行设计

## 职责与模块关系

拥有历史查询、归档修改与结果呈现。HistoryModule 绑定预览、修改和内部完整读取；查询服务、请求结果槽、标题任务及 UI 投影分别拥有明确状态。所有服务共享注入的 ConversationHistoryStore。

Gateway 通过注册函数调用本域，Agents 决定请求与策略，App 注入唯一基础能力和根生命周期。本域消费 FunctionContracts 及需要的基础能力，不导入 Agents、Gateway 实现或 App。全部域内源码由 Actions 单一目标编译。

## 目录与文件

| 文件 | 当前职责 |
| --- | --- |
| [ConversationActions.swift](ConversationActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [ConversationHistoryWorkflow.swift](ConversationHistoryWorkflow.swift) | 历史浏览请求、取消加入与有界图片读取 |
| [HistoryActions.swift](HistoryActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [HistoryCapabilities.swift](HistoryCapabilities.swift) | 历史引用、查询／修改／呈现端口 |
| [HistoryFullReadService.swift](HistoryFullReadService.swift) | 共享仓库的完整查询与照片读取 |
| [HistoryModule.swift](HistoryModule.swift) | 绑定预览、修改与完整读取函数 |
| [HistoryMutationService.swift](HistoryMutationService.swift) | 归档、删除及单槽标题工作 |
| [HistoryPresentationActions.swift](HistoryPresentationActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [HistoryPresentationAdapter.swift](HistoryPresentationAdapter.swift) | 仓库事实到 UI 值的版本化呈现 |
| [HistoryQueryService.swift](HistoryQueryService.swift) | 有界预览、分页与编码 |
| [HistoryReadRequest.swift](HistoryReadRequest.swift) | 完整读取查询／结果约束与单次请求结果槽 |

## 查询、修改与完成

预览按分页投影并限制 JSON 大小；完整读取经 HistoryReadInvocation 保存一个请求私有结果，验证来源、会话、输入身份与取消后完成，不创建全局请求表。HistoryMutationService 共享一个标题准入槽，自动标题和显式重试不并行创建第二套 worker；关闭加入标题工作，取消不能撤销已提交持久化。HistoryPresentationAdapter 通过 UI 公开端口提交真实仓库事实。

## 查询算法与数据约束

list 使用 store.listConversations 的当前会话与归档元数据，顺序沿用按 archivedAt 排序的索引，不加载归档正文。标题和 latestUser 预览各最多 40 UTF-8 字节，turnCount 取输入块数。

read 查找当前或归档会话并调用 `indexedHistory()`，按项目分页。request 项取请求输入与 完整 response 字符串，带请求状态及输入/Task 关联；task 项取 goal 与 reportedSummary/failure 的组合，带实际终态和 Task 身份。user/response 分别限 80/160 UTF-8 字节，total 计算投影项数。

Text 按 Swift Character 逐个累计字节，保留完整字符，并明确提供 truncated。Page 使用 ISO8601 日期、排序键和无斜杠转义的 JSON；整体最多 1800 字节。服务再次验证页范围，错误编码为 missingConversation、resultTooLarge、currentConversation 对应的执行失败代码。

## 修改状态与失败处理

startNew 等待可恢复归档与新 current 创建，返回可选旧会话 ID，并提交根持有的单个标题任务；标题不阻塞新会话。deleteArchived 按ID读取会话，拒绝当前或不存在的会话，在删除前检查取消，再等待仓库原子修改。

summarizeArchived 读取并验证归档会话，执行注入的异步标题计算，检查取消后调用 setTitle。计算或提交失败时尝试保存 nil 标题与最多 1024 字符的错误状态；该记录加入结束后才抛出原始错误。若记录失败，抛 ActionReportedError，包含 title 与 retryState 两条结果，保留主要和次要失败。

服务持有共享 actor 仓库和一个根所有者可取消/加入的标题 worker。自动标题与显式重试共用单个准入槽，溢出明确记录可重试失败；不创建第二个历史仓库或自动重试。取消不能撤销已经完成的持久化；并发与仓库一致性规则由 StorageChat 负责。查询和目录本身不授予历史访问或删除确认。


HistoryPresentationAdapter 编译到 Actions，将共享仓库事实转换为 UI 自有值并通过公开呈现接口提交，保留会话/版本围栏。UI 的完整读取由 Memory 直接接纳，经 Gateway → Actions 读取；每请求类型化执行附件承载真实结果，Memory 返回关联回执，纯查询不主动呈现第二次。



## 接口与结果

全部地址位于 `History.Conversation`，默认 timeout 为 30 秒，summarize 为 60 秒。

| 函数 | 参数 | 完成值 |
| --- | --- | --- |
| list | offset 0…64、limit 1…5 | 当前会话优先的会话元数据页 |
| read | id为list返回的ref或完整UUID、offset 0…1000000、limit 1…2 | 按仓库索引顺序排列的请求/压缩 Task 项目页 |
| startNew | 无 | archived ID 或 null |
| summarize | 已归档会话 id | 标题提交后返回 summarized ID |
| delete | 已归档会话 id | 删除提交后返回 deleted ID |

参数来自字符串传输，未知键被拒绝。list/read 结果最多 1800 UTF-8 字节，超过上限抛 resultTooLarge，不能裁掉 JSON 结构。页包含 items、total，存在更多内容时带 nextOffset；每次调用重新读取快照，不承诺跨调用分页稳定。

list 的 turnCount 是存储的输入块数量；read 的 total 是 indexedHistory 投影项数量，二者含义不同。read 项包含 kind=request/task、状态及适用的 taskID/inputID，读取已经持久化的请求片段或任务摘要，不生成摘要，也不执行历史函数。

[Actions 设计](../README.md) · [公共函数契约](../Support/Contracts/README.md)

## Execution ownership and lifecycle

HistoryReadInvocation is ActionRequestSlot<UI.HistoryInput, UI.HistoryReply>. HistoryActions converts the typed request, executes the same HistoryFullReadCapability and returns a typed private result. Session/input and duplicate checks remain local; role/Task authorization stays in Memory. ConversationHistoryWorkflow belongs to Actions and joins mutation/paging workers at shutdown. ActionsContainer retains title jobs and business services.
