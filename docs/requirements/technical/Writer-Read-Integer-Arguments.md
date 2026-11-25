# Writer 文件读取参数兼容

2026-11-24 真机 SQLite 的 `workspace_1` 第 9–11、15–17 条请求收到 HTTP 200。模型把 `read` 的 `limit` 或 `offset` 写成 JSON 整数，Responses 解码器在 `response.output_item.done` 拒绝了调用，两个委托均耗尽三次尝试。

## 实施计划

- 在 `ModelKit/Language/LLM/ChatCapability.swift` 给 ChatToolDefinition 增加调用方可选的整数兼容字段。仅允许对 schema 中声明为 string 的字段启用。
- 在 `Agents/Writer/Workflow/WriterTools.swift` 按注册路径为 `Artifacts.Workspace.read` 启用 `line`、`offset`、`limit`。对外工具定义维持字符串 schema，Actions 继续校验文件路径和范围。
- `ModelKit/Language/LLM/OpenAI/OpenAIChat.swift` 传递本轮显式启用的字段，`ChatEventDecoder.swift` 将这些字段收到的可表示整数转换为十进制字符串。原始增量、完成项及终态参数仍必须一致，传输采集保留原始响应。布尔值、小数、溢出整数及其他字段的非字符串输入仍明确失败。
- 更新 Writer 工作流、ModelKit Chat / Responses 及整体设计文档。用合成 SSE 重放真机故障中的参数形状，覆盖转换、原样字符串、超出兼容范围和终态篡改。运行工程检查和 Simulator 构建。

故障证据与构建、测试结果见[验证记录](../../validation/Writer-Read-Integer-Arguments.md)。
