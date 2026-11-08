# Assistant 对话详情精简

2026-11-08。仅修改 Assistant 的单轮详情，Writer 专属详情保持现有行为。

## 目标与实现计划

- 固定展示顺序：User Request、Assistant Response、Tasks、Skills、States、Function Catalog、Prompts、Generation Meta、清空该条日志按钮。
- Tasks/Skills/States 为同级独立区块；分别使用蓝色 checklist、紫色 square.stack.3d.up、橙色 square.stack.3d.down.right 图标。空值明确显示，无记录显示 Not recorded。
- Prompts 保留已格式化的消息、图片与工具定义，移除“完整请求”和“模型返回日志”原始 JSON 折叠项；移除 Action Execution 区块及仅用于该区块的解释请求。原始日志仍由日志表持有，导出与 Writer 详情不变。
- 日志按钮移至页尾，保留删除确认、忙态、失败提示。成功后清除页面缓存中的日志内容；清空状态下不显示 Prompts/Generation Meta/删除按钮，只显示一行英文 Logs cleared。业务字段、Function Catalog 保留。
- States 展示每轮实际采集的 State 路径，不重新读取当前 State 或按当前 Skill 定义推算历史。AgentChatWorker 将传给 multimodalSnapshot 的路径写入 AssistantDecisionMetadata.states，沿 assistant_messages.decision_json 持久化，不修改表结构。HistoryDecisionMetadata 增加对应可选投影，缺少历史证据时显示 Not recorded；State 的完整事实仍在可删除的 Prompts 日志中。
- 文件范围：UI/Settings/ConversationHistoryView、ConversationHistoryState、ConversationHistoryPresentation；Agents/Support/Chat/AgentChatWorker；Storage/Database/AssistantMessages/AssistantRecords；现有 UI 与 SQLite 历史测试。不得新增目录。
- 实现后同步 UI/Settings、Agents/Support/Chat、Storage/Database/AssistantMessages、Actions/History 和整体设计的读取/保存边界。补充清空日志后 States 持续存在及 UI 日志状态切换回归，执行 ./scripts/check.sh 与 ./scripts/build-ios.sh。

删除成功后的展示直接从当前详情生成去日志副本，清掉内存中的请求、图片来源和生成 meta，保留业务字段；不让后续重读失败把已经提交的清空误报为删除失败，也避免继续导出旧日志。后续重新打开详情仍由数据库读取实际结果。增加副本及导出回归。

Action Execution 是唯一消费 HistoryExecutionPreview 的页面入口，删除后同时移除已无调用者的 ConversationHistoryControlling.preview、ConversationHistoryWorkflow.previewOutput、ActionsDependencies/BusinessBindings 的 previewHistory 注入、App 适配与 MemoryContainer.previewHistory/HistoryExecutionPreview.swift。同步 Actions、App/Composition、Memory 的接口文档和构造测试，保留真实 Action 执行与持久化链路。

## 交付记录

上述页面、State 路径证据、日志清空副本、无用接口清理、回归与技术文档均已完成。完整检查脚本及四项 iOS 构建通过；原生视觉与真机边界见[验证记录](../validation/Assistant-Conversation-Detail.md)。

后续真机截图反馈将 Tasks、Skills、States、Function Catalog 合并到同一业务 Section，States 记录链路保持不变；见[详情修正](Writer-Record-Detail.md)。
