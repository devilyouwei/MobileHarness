# 打断决策记录与对话历史本地化

## 问题

- 输入决策证据把模型的布尔结果存成字符串 `"true"`/`"false"`，历史列表直接把它显示成蓝色标签，详情显示「决策：true」。实际语义是「这条输入是否打断了正在进行的回复」。
- 被打断的回复在历史里仍是 `completed`：生成通常已结束，只有播放被打断；取消路径则写成 `cancelled`。`interrupted` 状态只在重启恢复和 Agent 停止时出现。
- 对话详情与请求详情有大量字面量英文（`Text("User Request")` 等不经过 `AppLanguage`），状态词、响应状态、Token 报告等展示字符串也未本地化，导致中英混杂。

## 方案

### 数据（Storage、Agents）

- `AssistantInputCoordination` 及其 `Member` 以 `interrupt: Bool?` 取代 `decision: String?`：`true` 表示本条输入打断了此前回复，`false` 表示没有，`nil` 表示没有有效决策。解码兼容旧记录：`decision` 为 `"true"`/`"interrupt"` 映射为 `true`，其余字符串映射为 `false`；编码只写 `interrupt`。
- AssistantChatWorker 在 `completeInputDecision` 写入 `interrupt`。
- 实施打断时（`requestInterrupt`）把被打断请求写成 `interrupted`：生成仍在进行时，取消路径按该标记收尾为 `interrupted` 而不是 `cancelled`；生成已结束、仅播放被打断时，直接把该请求改写为 `interrupted`。批次成员随批次主请求同一状态收尾。

### 展示（UI/Settings）

- `HistoryInputCoordination` 同步使用 `interrupt` 并兼容旧值；删除 `decisionReport`。
- 列表：`interrupt == true` 显示红色「Interrupt decision / 打断决策」标签；`false` 不显示。被打断请求显示本地化状态 `interrupted`。
- 详情：区块标题「Interrupt decision / 打断决策」；行为「Interrupt: Yes/No」「是否打断：是/否」、来源、采集时间、决策路径、批次主输入、批次成员；`true` 时附说明「本条输入打断了正在进行的回复」。
- 状态词统一本地化：generating、completed、failed、cancelled、interrupted。
- ConversationHistoryView 与 ConversationHistoryPresentation 的用户可见字面量全部经 `AppLanguage` 解析，翻译加入 UI/Shared/Localizable.xcstrings；提示词、记录原文、ID、工具与路径保持原样。

### 文档与验证

- 实现后更新 Settings、AssistantMessages、Assistant README。
- 测试：旧 `decision` 值的解码兼容、新 `interrupt` 编解码、打断后被打断请求为 `interrupted`。
- 运行 `./scripts/check.sh`；有完整 Xcode 时运行 `./scripts/build-ios.sh`；真机与真实模型的验收单独记录。
