# RuntimeLog

`UIContainer.runtimeLog` 提供与首页会话独立的内存日志状态。将该实例传给 `RuntimeLogView(state:)` 即可挂载入口、Channel 摘要和记录面板。

在应用装配时把 `any RuntimeLogWriting` 注入日志生产者，在主 Actor 调用 `record(_:)` 提交已转换的 UI 值。Agent 生命周期用 `.agent`，调度快照用 `.actions`，Agent 内部 Control 终态用 `.agentControl`，输入决策用 `.decision`，运行异常用 `.issue`。例如：

```swift
await log.record(.agent(.init(source: "assistant", status: "已运行", isFailure: false)))
```

Gateway 调度通过 App 注入的快照回调供给 Action 日志。生产者可以省略写入端口，日志只用于呈现。日志组件按身份合并更新。Agent 状态、运行异常和 Decision 分别保留最近 100 条。Action 快照由调度器保留，覆盖所有活动记录和最近 100 个终态。Decision 记录路由、单次分类的 modelName、模型输出、采用值、简短原因以及单次分类所针对的输入原文。写入 `.decision` 时将分类快照中的文本传给 `DecisionLogItem.inputText`，包括用户键入内容、语音识别最终文本，以及 Decision 继续聆听后拼接的语音片段。分类日志可呈现 continue_listening。折叠时预览用户输入，展开可查看和复制模型请求上下文。每次分类只显示选定模型的实际请求；失败时记录兜底结果及原因，包括未就绪和超时（含等待旧调用清理超时），不存在本地失败后的云端请求或 localFallback 字段。每条记录以毫秒显示 Assistant 测得的完整分类耗时。首页提示独立接收已分类的异常。后台可保留证据，根停止后拒绝写入。State 标签只显示当前状态，不显示变化历史，由 `provideStateVariables` 注入的只读来源在标签可见时每 2 秒刷新，分两个列表：“Agent 状态”列出 Agent 自有变量（声明的只读/可读写变量与模型设置的语义变量，路径为 `agents.<agent>.<name>`），“Skill 状态”列出已加载 Skill 的容器路径（图像类仅标注，不读取）。点击有值的行展开当前值与写入时间（容器状态没有写入时间）；每个列表内有值的按最近变化倒序（变化时间取写入时间，缺失时取显示层比对出的变化时刻），无值的灰色、不可展开、排在最后。只读且不持久化。日志随 UI 根重建而清空。

首页入口的无障碍标签与面板标题随应用语言显示“Execution Log／执行日志”，通过环境 locale 与共享 AppLanguage 文案解析即时刷新。Action 摘要及列表使用注册函数路径 `Domain.Module.function`。统一列表按通道、来源和状态筛选。Agent 内部 Control 使用注册别名和 `Control` 标签，最近 100 个终态独立于调度快照保存。首页 Channel 摘要取自调度快照。标签用紧凑的彩色底和小内边距贴合文字，状态图标及颜色由执行阶段决定。展开记录可查看并复制实参和结果。参数按键显示，每个值最多 2048 UTF-8 字节，凭据字段隐藏。值、活动回执和结构化报告使用实际执行完成值，输出预览最多 16384 UTF-8 字节，超限标记截断。

模型 Decision 和关键词快停行共用“来源 · 路由 · 模型名”的标题格式。关键词快停行显示命中词、检测总耗时、累计推理耗时和清理后的打断结果，并按打断结果进入成功或失败筛选。缺少检测元数据的记录只显示原有的检测计时。UI 使用 Assistant 投影的结果与原因。


DecisionLogItem 可携带 booleanResult 和 signalStatus；新记录分别展示原始布尔值和打断信号执行状态。旧 disposition 字段仅保留历史展示兼容。错误不显示为 false。

被更新输入或已接纳的打断淘汰、且没有模型结果的 Decision 使用 `superseded` 路径和本地化状态，保留输入与实际请求证据。此类记录只出现在全部筛选，等待推理清理超时仍显示为失败。已经得到布尔结果的旧目标可同时显示模型结果与跳过打断的状态。
