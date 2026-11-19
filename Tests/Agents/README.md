# Agents tests

角色运行时、认知规则与跨模块业务协作。外围模型、设备、PCM 与部分呈现使用显式替身；真实 Gateway/Actions/Storage 链路按用例连接。

Core：配置、Task/Skill、状态、通信、失败与轮次；Assistant：对话、解析、历史和资源；Photographer：图像/跟踪及摄影；SpeechPerception：语音输入；Writer：委派、编辑和发布。

## 测试分层

采用 [Tests 的统一分层](../README.md#测试分层)。混合行表示文件中同时存在独立逻辑单元与真实组件协作；按实际用例边界判断，不按 target 命名判断。

| 能力目录 | 层级 | 文件或用例组 |
| --- | --- | --- |
| Assistant | Integration Tests | [AssistantChatTests](Assistant/AssistantChatTests.swift)、[ConversationHistoryTests](Assistant/ConversationHistoryTests.swift)、[HistoryIntentTests](Assistant/HistoryIntentTests.swift)、[InteractionPipelineTests](Assistant/InteractionPipelineTests.swift)、[ResourceHostFailureTests](Assistant/ResourceHostFailureTests.swift)、[ResourceIntentTests](Assistant/ResourceIntentTests.swift)、[ResourceObservationTests](Assistant/ResourceObservationTests.swift)、[ResourcePresentationTests](Assistant/ResourcePresentationTests.swift) |
| Assistant | Unit Tests / Integration Tests | [AssistantEvaluationRunnerTests](Assistant/AssistantEvaluationRunnerTests.swift)、[FunctionTokenParserTests](Assistant/FunctionTokenParserTests.swift)、[InputDecisionTests](Assistant/InputDecisionTests.swift)、[PromptTemplateTests](Assistant/PromptTemplateTests.swift) |
| Assistant | Unit Tests | [SentenceFunctionTests](Assistant/SentenceFunctionTests.swift) |
| Core | Unit Tests / Integration Tests | [AgentArchitectureTests](Core/AgentArchitectureTests.swift)、[AgentTaskSkillTests](Core/AgentTaskSkillTests.swift)、[ContainerContextTests](Core/ContainerContextTests.swift)、[GenerationRoundTests](Core/GenerationRoundTests.swift)、[AgentContainerTests](Core/AgentContainerTests.swift) |
| Core | Unit Tests | [AgentConfigurationTests](Core/AgentConfigurationTests.swift)、[BehaviorTranslationTests](Core/BehaviorTranslationTests.swift)、[GenerationObservationTests](Core/GenerationObservationTests.swift) |
| Core | Integration Tests | [AgentSpecialistTests](Core/AgentSpecialistTests.swift)、[CommunicationTests](Core/CommunicationTests.swift)、[ContainerFailureTests](Core/ContainerFailureTests.swift)、[RuntimeTests](Core/RuntimeTests.swift) |
| Photographer | Unit Tests | [CameraSamplingTests](Photographer/CameraSamplingTests.swift)、[EyeTrackingTests](Photographer/EyeTrackingTests.swift) |
| Photographer | Unit Tests / Integration Tests | [PhotoFeedbackTests](Photographer/PhotoFeedbackTests.swift)、[PhotographyPipelineTests](Photographer/PhotographyPipelineTests.swift) |
| Photographer | Integration Tests | [PhotographerCameraTests](Photographer/PhotographerCameraTests.swift) |
| SpeechPerception | Unit Tests / Integration Tests | [SoundSourceTests](SpeechPerception/SoundSourceTests.swift)、[VoiceTests](SpeechPerception/VoiceTests.swift) |
| SpeechPerception | Integration Tests | [SpeechEnhancementWorkflowTests](SpeechPerception/SpeechEnhancementWorkflowTests.swift) |
| Writer | Integration Tests | [WriterAgentTests](Writer/WriterAgentTests.swift)、[WriterEvaluationRunnerTests](Writer/WriterEvaluationRunnerTests.swift) |
| Writer | Unit Tests / Integration Tests | [WriterWorkflowTests](Writer/WriterWorkflowTests.swift) |

## 执行与替身边界

默认执行 `./scripts/check.sh`；实际期限与原生窗口回归由既有串行阶段隔离。模型/网络/设备开关与原生独立入口见 所属能力 README 和 [执行总索引](../README.md#执行入口)。每次运行单独记录通过、失败与跳过，不将替身结果标成原生验收。

## 辅助代码

[AssistantCommunicationFixture](Assistant/AssistantCommunicationFixture.swift)、[ContainerExecutionFixtures](Support/ContainerExecutionFixtures.swift)、[DirectInputSupport](Support/DirectInputSupport.swift)、[FixedTextChat](Support/FixedTextChat.swift)、[FixtureCommunications](Support/FixtureCommunications.swift)、[SpeechRequestProbe](Support/SpeechRequestProbe.swift)、[WorkflowCatalogFixture](Support/WorkflowCatalogFixture.swift)、[WriterCommunicationFixture](Writer/WriterCommunicationFixture.swift) 提供所属编译目标的夹具、探针或注册，不是独立测试层。

## 能力文档

- [Assistant](Assistant/README.md)
- [Core](Core/README.md)
- [Photographer](Photographer/README.md)
- [SpeechPerception](SpeechPerception/README.md)
- [Support](Support/README.md)
- [Writer](Writer/README.md)
