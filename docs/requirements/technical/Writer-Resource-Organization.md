# Writer 提示词与续写上下文整理

2026-11-12。按已确认的审计结果整理 Writer 的模型提示词和通信说明。

## 资源归属

| 文件 | 职责 |
| --- | --- |
| `Instructions.md` | Writer 私有控制身份与通用追问、完成规则。Skill 按作品库与文件编辑分别维护操作顺序和示例。 |
| `Prompts.json` | 作品库及编辑域控制请求，合并 `ControlContext.json`，加入追问回答模板。 |
| `ContentPrompts.json` | 无工具内容请求。合并 `ContentInstructions.md`、`ContentContext.json` 与 `Prompts.json` 的内容字段，并保存路径、选区及相关文件的呈现模板。 |
| `Recovery.json` | 模型请求失败、工具修正与历史恢复。 |
| `WorkspaceFeedback.json` | Writer 工作区操作反馈和前置条件。 |

## 续写接口

Artifacts 校验读引用和范围，维持原编辑事务和取消边界。内部 edit 接纳结果包含 streamID、原始 instruction、路径、项目文件或选区以及相关文件的结构化事实。Writer 接收该值，按实际路径选择内容格式、围栏检查和历史路径，用资源组装模型消息。保留选区、相邻文本、换行信息与相关文件范围；内容失败先 abort，再重新取得完整的新续写准备值。普通工具说明、返回结果和异常由 Actions 拥有。

## 通信与验证

Writer 的三个定向输入与两个定向发送有独立调用用途，沿用现有契约。进度通过 AgentMessaging.sendResult 返回的 DeliveryReport 确认，持久终态仍独立重投。同步 Writer、Artifacts、共享续写契约与总体技术说明。

用实际请求回归核对控制域、追问补充、内容格式、选区及关联文件、重试重开和路径记录。运行完整检查和 iOS 构建，校验包内 Writer 资源及旧文件移除。

运行结果见[验证记录](../../validation/Writer-Resource-Organization.md)。
