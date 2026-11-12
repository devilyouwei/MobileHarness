# Agent 共享提示词

Shared 保存 cognition Agent 可以复用、没有特定角色所有权的提示词。共享不代表自动注入：每个请求按实际协议和授权选取资源，资源不授予能力。

- OutputProtocol.md：完整固定 Action 输出协议；Assistant 的输入政策在 Assistant/InputProtocol.json。
- ActionCatalog.json、SkillCatalog.json、AgentCatalog.json：动态目录章节与排版；函数描述继续由 Action 声明管理。
- RequestContext.json：Agent/State/图片清单的通用事实框架。
- ExecutionFeedback.json：调用拒绝、参数纠正和执行不确定性说明。
- CommunicationContext.json：真实通信权限的目录补充及通信拒绝提示。

完整固定指令用 Markdown；具名短片段和动态插值用 JSON。角色业务、身份、输入分类、Task 工作流和 Writer 恢复不放在 Shared。加载和变量校验由 [AgentPrompts](../../../Agents/Support/Chat/README.md) 负责。
