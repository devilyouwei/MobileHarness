# Assistant tests

## Static instruction growth limits

PromptTemplateTests bounds the assembled Assistant static instruction/catalog text to fewer than 25,000 UTF-8 bytes for base Skills and 32,000 with Photography. These are regression thresholds for instruction growth, not token counts or model context windows. Dynamic State and complete-request runtime limits are independent; catalog and safety assertions remain enforced.

## Prompt ownership coverage

AgentConfigurationTests cover v10 public role metadata projected to the v8 compiled contract, missing/invalid/oversized descriptions, unknown fields and identity mismatch. PromptTemplateTests cover instance-permission filtering, exclusion of unsupported peers and private instructions, generic peer Task teaching, and Writer format/retry templates. Existing task, cancellation, library and Writer workflow tests exercise the execution boundary independently of public descriptions.

## 文件归属

- [AssistantChatTests.swift](AssistantChatTests.swift)
- [ConversationHistoryTests.swift](ConversationHistoryTests.swift)
- [FunctionTokenParserTests.swift](FunctionTokenParserTests.swift)
- [HistoryIntentTests.swift](HistoryIntentTests.swift)
- [InputDecisionTests.swift](InputDecisionTests.swift)
- [InteractionPipelineTests.swift](InteractionPipelineTests.swift)
- [PromptTemplateTests.swift](PromptTemplateTests.swift)
- [ResourceHostFailureTests.swift](ResourceHostFailureTests.swift)
- [ResourceIntentTests.swift](ResourceIntentTests.swift)
- [ResourceObservationTests.swift](ResourceObservationTests.swift)
- [ResourcePresentationTests.swift](ResourcePresentationTests.swift)
- [SentenceFunctionTests.swift](SentenceFunctionTests.swift)

[AssistantEvaluationRunnerTests.swift](AssistantEvaluationRunnerTests.swift) 拥有通信辅助机制的确定性回归及单模型、单任务、最多8次请求的 smoke（默认关闭）。多 case/模型效果对照归 experiments。


[AssistantCommunicationFixture.swift](AssistantCommunicationFixture.swift) 提供真实 Assistant/Gateway 单请求 smoke 与确定性协议回归的合成端点；没有多 case 真实模型评估入口。

InputDecisionTests 的 latest-wins 回归用可控慢清理的 Decision 替身验证取消后不重入、只推理最新候选、过时结果不打断、等待截止后超时及退出后恢复；Agent 集成验证被替代输入仍进入下一批。替身结果不证明真实 Laya/CoreAI 在真机上能响应取消。
