# 打断决策记录与对话历史本地化

## 将关键词决策关联到触发输入

- Assistant 按当前语音会话内的采集代际和话段 ID 关联关键词命中与 ASR 终稿。任意到达顺序均可关联。仅在旧回复清理及结算成功后，把关键词决策写到同一话段的已接纳文本输入。空转写只保留被打断回复的已有证据。
- 保留输入和批次归属。若合批的触发输入不是主输入，历史列表和详情从批次成员的已确认决策读取来源。迟到或未胜出的模型判定不能覆盖已确认的关键词决策。
- 验证真机 SQLite 旧记录、两种到达顺序、合批次要成员、数据库重读和详情投影。历史数据不根据时间或文字猜测关联。

## 统一关键字与模型打断的历史结算

- Assistant 在共同的清理确认点写入被打断请求的 Action 片段、原始生成文本、胜出路径和来源。模型沿用原触发输入的历史证据。关键词无需等待 ASR 终稿即可在被打断回复上显示决策。未胜出或清理失败的模型判定不可将输入标为已打断。
- Storage 为已打断的已发请求保留结构化标记，即使完成片段拼接恰好与原文相同。已发请求从模型派发时开始记录完成片段。已有提示资源渲染 JSON，历史详情显示该标记，原回复和完整生成证据保留独立语义。缺少可靠归因的历史维持原记录。
- SQLite 分页和详情投影携带胜出路径，历史列表和详情识别两种来源。验证两种来源和共用结算、零 Action 或全文保留、SQLite 读回、模型上下文和列表／详情投影。

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

## 打断判定请求正文

- Assistant 输入入口在接收忙时输入时冻结当前回复已输出的自然语言片段和用户最新输入。当前回复尚无文本时传空字符串。用户的上一条请求、批处理文本和工具返回不进入判定请求。
- `AssistantChatWorker.swift` 保留回复身份与已输出文本，`AssistantChatInput.swift` 传递冻结的文本，`AssistantInputDecision.swift` 负责渲染双语正文和问题。已有目标校验、排队和清理流程继续使用原有接口。

## 简化打断提问

- `AssistantInputDecision.swift` 使用双语 `InputDecision*.json` 把冻结的回复和最新输入放进一句自然语言描述，再单独传入同一句式的是否打断问题。中文渲染为「当前你正在说“［助手回复］”，此时用户对你说“［最新输入］”，请问：用户说这句话是否包含打断你的意图？」。沿用 `noul` 的正文和问题接口。两段原文作为模板变量插入。
- 用 Swift 校验中英准确措辞、空回复、旧消息不进入请求，以及原生 Decision 和 Chat 后端收到同一语义。同步 Assistant 技术说明。Quiet 唤醒管理继续使用自身的提示词。

## Laya token 容量兜底

- `ModelKit/Language/JEV/LayaDecision.swift` 在 Laya 编码层组装张量。参考 D3 保留最近 token 的方式，从正文末尾取问题头和两个分隔符之后剩余的 token 预算。Choice 和 noul 共用输入组装。
- 保留完整问题、选项和 marker，问题或选项超预算仍明确报错。序列仍右填充到模型窗口。Assistant 请求继续分开传递正文和问题。
- 更新 JEV README。ModelKit 回归覆盖完整头部、正文尾部、分隔符、mask 和候选超限。原生 Laya 冒烟验证超长正文可返回单个结果。
