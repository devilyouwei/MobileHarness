# Agent/model evaluations

Purpose: Evaluate actual Agent prompts and generated Action markup through Gemma 4 E2B. These are application integration experiments outside ModelKit.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- HARNESS_EVAL_GEMMA4=1 enables serialized synthetic prompt comparisons; results go to /tmp/gemma4-prompt-variants.json. Scenarios are application evaluation data, separate from backend contract tests.

The comparison variant uses the complete current English Assistant system prompt, including registered text mappings and declared Channels. Archived baseline fixtures are evaluation data only.

JSON v5 uses Channel-grouped callable Actions; Assistant text interpretation uses Assistant.mapText rather than JSON aliases. Regression coverage checks internal permissions cannot be called through model markup and preserves wait event order.

Chat output-token budgets are optional and default to nil. Assistant/cloud requests omit max_tokens so the provider chooses its default; local Gemma 4 E2B uses remaining room in its existing 4096-token context. History shows 模型默认 for omitted values and preserves older explicit budgets. Parser, queue and per-segment limits are independent of output-token budgets.

## 待实现

- 更广泛的真实模型质量、Provider 兼容性和设备端多轮流程验收。千问调用样本与已知失败见 validation，默认测试不加载权重。

✅ 千问共用 Action/Tool 工作流由 [IntegrationTests](../IntegrationTests/README.md#千问-action--tool-回归) 执行生产 Agent/Gateway 链路；本目录只拥有场景数据。`scripts/evaluate-qwen.py` 显式读取被忽略的本地 ENV，仅将阿里凭据传入测试子进程，不访问 OpenAI。报告区分协议/流程失败、传输失败和合成设备反馈。

内置 Skill 的生产目录为 Action-only；共享云场景同时检查真实请求没有原生 Tool 声明。底层 Tool/混合协议测试在 IntegrationTests 独立保留，不以生产 Skill 注册作为 native fixture。

Writer 的独立原生协议回归位于 `IntegrationTests/WriterModelEvaluationTests.swift`，不是 Assistant XML/Skill 场景。`scripts/evaluate-writer.py` 分别运行 Qwen 与 DeepSeek，使用实际 Writer/Gateway/Storage 和本机 WebKit。凭据隔离、复现和限制见 [scripts](../../scripts/README.md#writer-双模型回归)，结果见 [专项报告](../../docs/validation/Writer-Model-Regression.md)。

Writer 的 JSON 提示词矩阵使用同目录 `Scenarios/writer-workflows.json` 和 `writer-evaluation.json`；`evaluate-writer.py --matrix` 默认只测 Qwen3.8 Max、GPT6.1 sol，旧六场景模式仍可显式选择其他已有模型。原生评估仍归 IntegrationTests；结果见 [Writer 提示词优化](../../docs/validation/Writer-Prompt-Optimization.md)。
