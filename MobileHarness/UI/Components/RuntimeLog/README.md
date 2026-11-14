# RuntimeLog

`UIContainer.runtimeLog` 提供与首页会话独立的内存日志状态。将该实例传给 `RuntimeLogView(state:)` 即可挂载入口、Channel 摘要和记录面板。

在应用装配时把 `any RuntimeLogWriting` 注入日志生产者，在主 Actor 调用 `record(_:)` 提交已转换的 UI 值。Agent 生命周期用 `.agent`，Task 进度用 `.task`，调度快照用 `.actions`，输入决策用 `.decision`，运行异常用 `.issue`。例如：

```swift
await log.record(.agent(.init(source: "assistant", status: "已运行", isFailure: false)))
```

Gateway 调度通过 App 注入的快照回调供给 Action 日志。生产者可以省略写入端口，日志只用于呈现。日志组件按身份合并更新。Agent 状态、运行异常、Task 和 Decision 分别保留最近 100 条，每个 Task 保留最近 32 个事件。Action 快照由调度器保留，覆盖所有活动记录和最近 100 个终态。Decision 记录路由、模型输出、采用值、简短原因以及单次分类所针对的输入原文。写入 `.decision` 时将分类快照中的文本传给 `DecisionLogItem.inputText`，包括用户键入内容或语音识别最终文本。折叠时预览用户输入，展开可查看和复制模型请求上下文。本地与云端尝试按调用顺序显示，未调用模型的回退明确标出。本地回退原因随分类结果显示，包括未就绪、超时和上次调用仍在清理。每条记录以毫秒显示 Assistant 测得的完整分类耗时。首页提示独立接收已分类的异常。后台可保留证据，根停止后拒绝写入。日志随 UI 根重建而清空。

首页入口的无障碍标签与面板标题随应用语言显示“Execution Log／执行日志”，通过环境 locale 与共享 AppLanguage 文案解析即时刷新。Action 摘要及列表使用注册函数路径 `Domain.Module.function`。列表按真实 Channel、来源、状态及关联任务筛选，Channel 彩色标签显示通道，状态图标及颜色由执行阶段决定。展开 Action 可查看并复制实参和结果。参数按键显示，每个值最多 2048 UTF-8 字节，凭据字段隐藏。值、活动回执和结构化报告使用实际执行完成值，输出预览最多 16384 UTF-8 字节，超限标记截断。
