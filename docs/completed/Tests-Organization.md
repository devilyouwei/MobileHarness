# Tests 职责聚类整理

## 目标与授权

按 ModelKit、Agents、Actions、Gateway、PlatformKit、Storage、App、UI 聚类，同类测试、辅助代码和评测资源归属同一能力。用户已批准新增这些分类及必要子目录。Tests 根仅保留全局导航。

## 实施约束

先记录本映射再迁移；保留现有 target 名称、依赖、测试标识、断言、live gates 和串行阶段。Package.swift 显式维护原编译成员；独立 Decision 包保留自己的依赖边界。Xcode、脚本、忽略规则、文件定位及文档链接同步迁移。原有工作区修改与未跟踪实验内容保留。历史测量 JSON 与 hash 不改写，原始设计 Word 不动。

测试辅助声明由能力目录或 Support 拥有，跨模块用例以主要断言和完成语义归属；原 IntegrationTests 编译单元保留，其目录不再作为分类。原综合契约说明按职责拆入各分类 README，不保留 IntegrationTests 目录或重复入口。

## 验证

比较迁移前后 target 成员和测试发现清单，验证所有三个 Python 离线套件、资源及文档路径、独立包清单、git diff --check；执行 scripts/check.sh 和可用时的 scripts/build-ios.sh。真实模型、网络、原生 UI 及物理设备不自动启用。结果另记 docs/validation/Tests-Organization.md。

## 文件映射

| 原路径 | 新路径 |
| --- | --- |
| `Tests/AgentModelEvaluationTests/AssistantPromptEvaluationTests.swift` | `Tests/Agents/Evaluation/Assistant/AssistantPromptEvaluationTests.swift` |
| `Tests/AgentModelEvaluationTests/README.md` | `Tests/Agents/Evaluation/README.md` |
| `Tests/AgentModelEvaluationTests/Scenarios/README.md` | `Tests/Agents/Evaluation/Scenarios/README.md` |
| `Tests/AgentModelEvaluationTests/Scenarios/cases.json` | `Tests/Agents/Evaluation/Scenarios/cases.json` |
| `Tests/AgentModelEvaluationTests/Scenarios/qwen-workflows.json` | `Tests/Agents/Evaluation/Scenarios/qwen-workflows.json` |
| `Tests/AgentModelEvaluationTests/Scenarios/writer-evaluation.json` | `Tests/Agents/Evaluation/Scenarios/writer-evaluation.json` |
| `Tests/AgentModelEvaluationTests/Scenarios/writer-workflows.json` | `Tests/Agents/Evaluation/Scenarios/writer-workflows.json` |
| `Tests/AppWorkflowTests/ActionActivityTests.swift` | `Tests/App/Presentation/ActionActivityTests.swift` |
| `Tests/AppWorkflowTests/ApplicationEnvironmentInputsTests.swift` | `Tests/App/Lifecycle/ApplicationEnvironmentInputsTests.swift` |
| `Tests/AppWorkflowTests/ApplicationLifecycleTests.swift` | `Tests/App/Lifecycle/ApplicationLifecycleTests.swift` |
| `Tests/AppWorkflowTests/AudioDetectionWorkflowTests.swift` | `Tests/App/Speech/AudioDetectionWorkflowTests.swift` |
| `Tests/AppWorkflowTests/CameraVisionRestartTests.swift` | `Tests/App/Camera/CameraVisionRestartTests.swift` |
| `Tests/AppWorkflowTests/ConversationHistoryWorkflowTests.swift` | `Tests/App/Presentation/ConversationHistoryWorkflowTests.swift` |
| `Tests/AppWorkflowTests/ConversationPresentationTests.swift` | `Tests/App/Presentation/ConversationPresentationTests.swift` |
| `Tests/AppWorkflowTests/HomeEffectsTests.swift` | `Tests/App/Presentation/HomeEffectsTests.swift` |
| `Tests/AppWorkflowTests/IndependentOutputTests.swift` | `Tests/App/Lifecycle/IndependentOutputTests.swift` |
| `Tests/AppWorkflowTests/ListeningActivationTests.swift` | `Tests/App/Speech/ListeningActivationTests.swift` |
| `Tests/AppWorkflowTests/ListeningCaptureWorkflowTests.swift` | `Tests/App/Speech/ListeningCaptureWorkflowTests.swift` |
| `Tests/AppWorkflowTests/ModelResourceInteractionWorkflowTests.swift` | `Tests/App/Resources/ModelResourceInteractionWorkflowTests.swift` |
| `Tests/AppWorkflowTests/ModelResourcesWorkflowTests.swift` | `Tests/App/Resources/ModelResourcesWorkflowTests.swift` |
| `Tests/AppWorkflowTests/NativeInteractionWorkflowTests.swift` | `Tests/App/Presentation/NativeInteractionWorkflowTests.swift` |
| `Tests/AppWorkflowTests/PhotoDispositionWorkflowTests.swift` | `Tests/App/Camera/PhotoDispositionWorkflowTests.swift` |
| `Tests/AppWorkflowTests/README.md` | `Tests/App/README.md` |
| `Tests/AppWorkflowTests/ResourceObservationWorkflowTests.swift` | `Tests/App/Resources/ResourceObservationWorkflowTests.swift` |
| `Tests/AppWorkflowTests/SettingsInteractionTests.swift` | `Tests/App/Settings/SettingsInteractionTests.swift` |
| `Tests/AppWorkflowTests/SettingsTransactionTests.swift` | `Tests/App/Settings/SettingsTransactionTests.swift` |
| `Tests/AppWorkflowTests/WebWorkspaceTests.swift` | `Tests/App/Web/WebWorkspaceTests.swift` |
| `Tests/AppWorkflowTests/WindowExecutionTests.swift` | `Tests/App/Presentation/WindowExecutionTests.swift` |
| `Tests/AppWorkflowTests/WriterWorkflowTests.swift` | `Tests/Agents/Writer/WriterWorkflowTests.swift` |
| `Tests/DecisionBenchmarks/DecisionDecoder.swift` | `Tests/Agents/Evaluation/Decision/Benchmark/DecisionDecoder.swift` |
| `Tests/DecisionBenchmarks/Package.resolved` | `Tests/Agents/Evaluation/Decision/Benchmark/Package.resolved` |
| `Tests/DecisionBenchmarks/Package.swift` | `Tests/Agents/Evaluation/Decision/Benchmark/Package.swift` |
| `Tests/DecisionBenchmarks/README.md` | `Tests/Agents/Evaluation/Decision/Benchmark/README.md` |
| `Tests/DecisionBenchmarks/app_binary_parity.py` | `Tests/Agents/Evaluation/Decision/Benchmark/app_binary_parity.py` |
| `Tests/DecisionBenchmarks/benchmark.py` | `Tests/Agents/Evaluation/Decision/Benchmark/benchmark.py` |
| `Tests/DecisionBenchmarks/binary_interrupt_experiment.py` | `Tests/Agents/Evaluation/Decision/Benchmark/binary_interrupt_experiment.py` |
| `Tests/DecisionBenchmarks/concise_intent_experiment.py` | `Tests/Agents/Evaluation/Decision/Benchmark/concise_intent_experiment.py` |
| `Tests/DecisionBenchmarks/continuation_prompt_experiment.py` | `Tests/Agents/Evaluation/Decision/Benchmark/continuation_prompt_experiment.py` |
| `Tests/DecisionBenchmarks/d3_cpu_comparison.py` | `Tests/Agents/Evaluation/Decision/Benchmark/d3_cpu_comparison.py` |
| `Tests/DecisionBenchmarks/decision_adapter_parity.py` | `Tests/Agents/Evaluation/Decision/Benchmark/decision_adapter_parity.py` |
| `Tests/DecisionBenchmarks/defined_intent_experiment.py` | `Tests/Agents/Evaluation/Decision/Benchmark/defined_intent_experiment.py` |
| `Tests/DecisionBenchmarks/fixtures.json` | `Tests/Agents/Evaluation/Decision/Benchmark/fixtures.json` |
| `Tests/DecisionBenchmarks/history_binary_experiment.py` | `Tests/Agents/Evaluation/Decision/Benchmark/history_binary_experiment.py` |
| `Tests/DecisionBenchmarks/laya-model.json` | `Tests/Agents/Evaluation/Decision/Benchmark/laya-model.json` |
| `Tests/DecisionBenchmarks/laya-unloadable-model.json` | `Tests/Agents/Evaluation/Decision/Benchmark/laya-unloadable-model.json` |
| `Tests/DecisionBenchmarks/laya_artifact_adapter.py` | `Tests/Agents/Evaluation/Decision/Benchmark/laya_artifact_adapter.py` |
| `Tests/DecisionBenchmarks/laya_compare_results.py` | `Tests/Agents/Evaluation/Decision/Benchmark/laya_compare_results.py` |
| `Tests/DecisionBenchmarks/laya_comparison.py` | `Tests/Agents/Evaluation/Decision/Benchmark/laya_comparison.py` |
| `Tests/DecisionBenchmarks/laya_parity.py` | `Tests/Agents/Evaluation/Decision/Benchmark/laya_parity.py` |
| `Tests/DecisionBenchmarks/localized_binary_experiment.py` | `Tests/Agents/Evaluation/Decision/Benchmark/localized_binary_experiment.py` |
| `Tests/DecisionBenchmarks/models.json` | `Tests/Agents/Evaluation/Decision/Benchmark/models.json` |
| `Tests/DecisionBenchmarks/multi_noul_experiment.py` | `Tests/Agents/Evaluation/Decision/Benchmark/multi_noul_experiment.py` |
| `Tests/DecisionBenchmarks/requirements.txt` | `Tests/Agents/Evaluation/Decision/Benchmark/requirements.txt` |
| `Tests/DecisionBenchmarks/summarize_continuation.py` | `Tests/Agents/Evaluation/Decision/Benchmark/summarize_continuation.py` |
| `Tests/DecisionBenchmarks/vela-model.json` | `Tests/Agents/Evaluation/Decision/Benchmark/vela-model.json` |
| `Tests/DecisionBenchmarks/vela31-model.json` | `Tests/Agents/Evaluation/Decision/Benchmark/vela31-model.json` |
| `Tests/DecisionBenchmarks/vela31_compare_results.py` | `Tests/Agents/Evaluation/Decision/Benchmark/vela31_compare_results.py` |
| `Tests/DecisionBenchmarks/vela31_comparison.py` | `Tests/Agents/Evaluation/Decision/Benchmark/vela31_comparison.py` |
| `Tests/DecisionBenchmarks/vela31_described_noul.py` | `Tests/Agents/Evaluation/Decision/Benchmark/vela31_described_noul.py` |
| `Tests/DecisionBenchmarks/vela31_parity.py` | `Tests/Agents/Evaluation/Decision/Benchmark/vela31_parity.py` |
| `Tests/DecisionBenchmarks/vela_comparison.py` | `Tests/Agents/Evaluation/Decision/Benchmark/vela_comparison.py` |
| `Tests/EnergyVADTests/EnergyVADTests.swift` | `Tests/ModelKit/Speech/VAD/Energy/EnergyVADTests.swift` |
| `Tests/EnergyVADTests/README.md` | `Tests/ModelKit/Speech/VAD/Energy/README.md` |
| `Tests/FunctionContractTests/FunctionContractTests.swift` | `Tests/Actions/Contracts/Functions/FunctionContractTests.swift` |
| `Tests/FunctionContractTests/README.md` | `Tests/Actions/Contracts/Functions/README.md` |
| `Tests/Gemma4Tests/Gemma4Tests.swift` | `Tests/ModelKit/Language/Gemma4/Gemma4Tests.swift` |
| `Tests/Gemma4Tests/GemmaDecisionEvaluationTests.swift` | `Tests/Agents/Evaluation/Decision/GemmaDecisionEvaluationTests.swift` |
| `Tests/Gemma4Tests/GemmaToolProtocolTests.swift` | `Tests/ModelKit/Language/Gemma4/GemmaToolProtocolTests.swift` |
| `Tests/Gemma4Tests/README.md` | `Tests/ModelKit/Language/Gemma4/README.md` |
| `Tests/Gemma4Tests/gemma4-e2b-macos.download.json` | `Tests/ModelKit/Language/Gemma4/gemma4-e2b-macos.download.json` |
| `Tests/IntegrationTests/ActionAuthoringTests.swift` | `Tests/Actions/Contracts/ActionAuthoringTests.swift` |
| `Tests/IntegrationTests/ActionCatalogFixture.swift` | `Tests/Actions/Support/ActionCatalogFixture.swift` |
| `Tests/IntegrationTests/ActionCompositionTests.swift` | `Tests/Actions/Execution/ActionCompositionTests.swift` |
| `Tests/IntegrationTests/ActionContractTests.swift` | `Tests/Actions/Contracts/ActionContractTests.swift` |
| `Tests/IntegrationTests/ActionDeclarationTests.swift` | `Tests/Actions/Contracts/ActionDeclarationTests.swift` |
| `Tests/IntegrationTests/ActionExecutionTests.swift` | `Tests/Gateway/Output/ChannelSchedulerTests.swift` |
| `Tests/IntegrationTests/ActionLifecycleTests.swift` | `Tests/Actions/Execution/ActionLifecycleTests.swift` |
| `Tests/IntegrationTests/ActionObservationTests.swift` | `Tests/Actions/Execution/ActionObservationTests.swift` |
| `Tests/IntegrationTests/ActionTestRegistry.swift` | `Tests/Actions/Support/ActionTestRegistry.swift` |
| `Tests/IntegrationTests/ActionsContainerTests.swift` | `Tests/Actions/Execution/ActionsContainerTests.swift` |
| `Tests/IntegrationTests/AgentArchitectureTests.swift` | `Tests/Agents/Core/AgentArchitectureTests.swift` |
| `Tests/IntegrationTests/AgentConfigurationTests.swift` | `Tests/Agents/Core/AgentConfigurationTests.swift` |
| `Tests/IntegrationTests/AgentContainerTests.swift` | `Tests/Agents/Core/AgentContainerTests.swift` |
| `Tests/IntegrationTests/AgentSpecialistTests.swift` | `Tests/Agents/Core/AgentSpecialistTests.swift` |
| `Tests/IntegrationTests/AgentTaskSkillTests.swift` | `Tests/Agents/Core/AgentTaskSkillTests.swift` |
| `Tests/IntegrationTests/AlbumNavigationTests.swift` | `Tests/Actions/UI/AlbumNavigationTests.swift` |
| `Tests/IntegrationTests/AlbumTests.swift` | `Tests/Storage/Database/AlbumTests.swift` |
| `Tests/IntegrationTests/AppleDecisionEvaluationTests.swift` | `Tests/Agents/Evaluation/Decision/AppleDecisionEvaluationTests.swift` |
| `Tests/IntegrationTests/AssistantChatTests.swift` | `Tests/Agents/Assistant/AssistantChatTests.swift` |
| `Tests/IntegrationTests/AudioCaptureReadinessTests.swift` | `Tests/PlatformKit/Audio/AudioCaptureReadinessTests.swift` |
| `Tests/IntegrationTests/AudioSampleBufferReaderTests.swift` | `Tests/PlatformKit/Audio/AudioSampleBufferReaderTests.swift` |
| `Tests/IntegrationTests/BehaviorAssemblyTests.swift` | `Tests/Actions/Execution/BehaviorAssemblyTests.swift` |
| `Tests/IntegrationTests/BehaviorContractFixtures.swift` | `Tests/Actions/Support/BehaviorContractFixtures.swift` |
| `Tests/IntegrationTests/BehaviorTranslationTests.swift` | `Tests/Agents/Core/BehaviorTranslationTests.swift` |
| `Tests/IntegrationTests/CameraEnhancementTests.swift` | `Tests/Actions/Camera/CameraEnhancementTests.swift` |
| `Tests/IntegrationTests/CameraSamplingTests.swift` | `Tests/Agents/Photographer/CameraSamplingTests.swift` |
| `Tests/IntegrationTests/CommunicationTests.swift` | `Tests/Agents/Core/CommunicationTests.swift` |
| `Tests/IntegrationTests/ContainerContextTests.swift` | `Tests/Agents/Core/ContainerContextTests.swift` |
| `Tests/IntegrationTests/ContainerExecutionFixtures.swift` | `Tests/Agents/Support/ContainerExecutionFixtures.swift` |
| `Tests/IntegrationTests/ContainerFailureTests.swift` | `Tests/Agents/Core/ContainerFailureTests.swift` |
| `Tests/IntegrationTests/ConversationHistoryTests.swift` | `Tests/Agents/Assistant/ConversationHistoryTests.swift` |
| `Tests/IntegrationTests/DatabaseTableRecordTests.swift` | `Tests/Storage/Database/DatabaseTableRecordTests.swift` |
| `Tests/IntegrationTests/DecisionAdapterNativeTests.swift` | `Tests/Agents/Evaluation/Decision/DecisionAdapterNativeTests.swift` |
| `Tests/IntegrationTests/DecisionBinaryEvaluationTests.swift` | `Tests/Agents/Evaluation/Decision/DecisionBinaryEvaluationTests.swift` |
| `Tests/IntegrationTests/DecisionContinuationEvaluationTests.swift` | `Tests/Agents/Evaluation/Decision/DecisionContinuationEvaluationTests.swift` |
| `Tests/IntegrationTests/DecisionReadoutEvaluationTests.swift` | `Tests/Agents/Evaluation/Decision/DecisionReadoutEvaluationTests.swift` |
| `Tests/IntegrationTests/DecisionLanguageEvaluationTests.swift` | `Tests/Agents/Evaluation/Decision/DecisionLanguageEvaluationTests.swift` |
| `Tests/IntegrationTests/DecisionMultiNoulEvaluationTests.swift` | `Tests/Agents/Evaluation/Decision/DecisionMultiNoulEvaluationTests.swift` |
| `Tests/IntegrationTests/DecisionPromptEvaluationTests.swift` | `Tests/Agents/Evaluation/Decision/DecisionPromptEvaluationTests.swift` |
| `Tests/IntegrationTests/DecisionProtocolEvaluationTests.swift` | `Tests/Agents/Evaluation/Decision/DecisionProtocolEvaluationTests.swift` |
| `Tests/IntegrationTests/DecisionWeightArchiveTests.swift` | `Tests/Agents/Evaluation/Decision/DecisionWeightArchiveTests.swift` |
| `Tests/IntegrationTests/DeviceInputTests.swift` | `Tests/Gateway/Input/DeviceInputTests.swift` |
| `Tests/IntegrationTests/DirectInputSupport.swift` | `Tests/Agents/Support/DirectInputSupport.swift` |
| `Tests/IntegrationTests/EyeTrackingTests.swift` | `Tests/Agents/Photographer/EyeTrackingTests.swift` |
| `Tests/IntegrationTests/FeedbackActionTests.swift` | `Tests/Actions/UI/FeedbackActionTests.swift` |
| `Tests/IntegrationTests/FixedTextChat.swift` | `Tests/Agents/Support/FixedTextChat.swift` |
| `Tests/IntegrationTests/FixtureCommunications.swift` | `Tests/Agents/Support/FixtureCommunications.swift` |
| `Tests/IntegrationTests/FoundationFailureTests.swift` | `Tests/App/Composition/FoundationFailureTests.swift` |
| `Tests/IntegrationTests/FunctionTokenParserTests.swift` | `Tests/Agents/Assistant/FunctionTokenParserTests.swift` |
| `Tests/IntegrationTests/GatewayContainerTests.swift` | `Tests/Gateway/Output/GatewayContainerTests.swift` |
| `Tests/IntegrationTests/GenerationRoundTests.swift` | `Tests/Agents/Core/GenerationRoundTests.swift` |
| `Tests/IntegrationTests/HistoricalDecisionBenchmarkSupport.swift` | `Tests/Agents/Evaluation/Decision/HistoricalDecisionBenchmarkSupport.swift` |
| `Tests/IntegrationTests/HistoryIntentTests.swift` | `Tests/Agents/Assistant/HistoryIntentTests.swift` |
| `Tests/IntegrationTests/HistoryToolTests.swift` | `Tests/Actions/History/HistoryToolTests.swift` |
| `Tests/IntegrationTests/HomeEffectActionTests.swift` | `Tests/Actions/UI/HomeEffectActionTests.swift` |
| `Tests/IntegrationTests/InputDecisionTests.swift` | `Tests/Agents/Assistant/InputDecisionTests.swift` |
| `Tests/IntegrationTests/InteractionPipelineTests.swift` | `Tests/Agents/Assistant/InteractionPipelineTests.swift` |
| `Tests/IntegrationTests/IslandIntegrationTests.swift` | `Tests/UI/Container/IslandIntegrationTests.swift` |
| `Tests/IntegrationTests/LocalFileStoreTests.swift` | `Tests/Storage/Files/LocalFileStoreTests.swift` |
| `Tests/IntegrationTests/MediaTransportTests.swift` | `Tests/Gateway/Output/MediaTransportTests.swift` |
| `Tests/IntegrationTests/NativeAttachmentTests.swift` | `Tests/Gateway/Output/NativeAttachmentTests.swift` |
| `Tests/IntegrationTests/NativeImageCompressionTests.swift` | `Tests/PlatformKit/Vision/NativeImageCompressionTests.swift` |
| `Tests/IntegrationTests/NexArmAimTests.swift` | `Tests/Actions/NexArm/NexArmAimTests.swift` |
| `Tests/IntegrationTests/NexArmArrivalPolicyTests.swift` | `Tests/Actions/NexArm/NexArmArrivalPolicyTests.swift` |
| `Tests/IntegrationTests/NexArmBluetoothTests.swift` | `Tests/PlatformKit/Connectivity/NexArmBluetoothTests.swift` |
| `Tests/IntegrationTests/NexArmCausalTests.swift` | `Tests/Actions/NexArm/NexArmCausalTests.swift` |
| `Tests/IntegrationTests/NexArmLegacyArrivalTracker.swift` | `Tests/Actions/NexArm/NexArmLegacyArrivalTracker.swift` |
| `Tests/IntegrationTests/NexArmLegacyDiagnosticController.swift` | `Tests/Actions/NexArm/NexArmLegacyDiagnosticController.swift` |
| `Tests/IntegrationTests/NexArmSerialAcceptanceTests.swift` | `Tests/Actions/NexArm/NexArmSerialAcceptanceTests.swift` |
| `Tests/IntegrationTests/NexArmTelemetryTests.swift` | `Tests/Actions/NexArm/NexArmTelemetryTests.swift` |
| `Tests/IntegrationTests/NexArmTests.swift` | `Tests/Actions/NexArm/NexArmTests.swift` |
| `Tests/IntegrationTests/PCMResamplerTests.swift` | `Tests/PlatformKit/Audio/PCMResamplerTests.swift` |
| `Tests/IntegrationTests/PhotoFeedbackTests.swift` | `Tests/Agents/Photographer/PhotoFeedbackTests.swift` |
| `Tests/IntegrationTests/PhotographerCameraTests.swift` | `Tests/Agents/Photographer/PhotographerCameraTests.swift` |
| `Tests/IntegrationTests/PhotographyPipelineTests.swift` | `Tests/Agents/Photographer/PhotographyPipelineTests.swift` |
| `Tests/IntegrationTests/PlatformContainerTests.swift` | `Tests/PlatformKit/Core/PlatformContainerTests.swift` |
| `Tests/IntegrationTests/PlatformStateTests.swift` | `Tests/PlatformKit/Core/PlatformStateTests.swift` |
| `Tests/IntegrationTests/PromptTemplateTests.swift` | `Tests/Agents/Assistant/PromptTemplateTests.swift` |
| `Tests/IntegrationTests/ProviderDiscoveryTests.swift` | `Tests/Actions/System/ProviderDiscoveryTests.swift` |
| `Tests/IntegrationTests/ProviderSettingsTests.swift` | `Tests/Actions/System/ProviderSettingsTests.swift` |
| `Tests/IntegrationTests/QwenWorkflowEvaluationTests.swift` | `Tests/Agents/Evaluation/Assistant/QwenWorkflowEvaluationTests.swift` |
| `Tests/IntegrationTests/README.md` | `Tests/Agents/README.md` |
| `Tests/IntegrationTests/ResolvedCallSupport.swift` | `Tests/Actions/Support/ResolvedCallSupport.swift` |
| `Tests/IntegrationTests/ResourceHostFailureTests.swift` | `Tests/Agents/Assistant/ResourceHostFailureTests.swift` |
| `Tests/IntegrationTests/ResourceIntentTests.swift` | `Tests/Agents/Assistant/ResourceIntentTests.swift` |
| `Tests/IntegrationTests/ResourceInventoryTests.swift` | `Tests/Actions/System/ResourceInventoryTests.swift` |
| `Tests/IntegrationTests/ResourceObservationTests.swift` | `Tests/Agents/Assistant/ResourceObservationTests.swift` |
| `Tests/IntegrationTests/ResourcePreferencesTests.swift` | `Tests/Actions/System/ResourcePreferencesTests.swift` |
| `Tests/IntegrationTests/ResourcePresentationTests.swift` | `Tests/Agents/Assistant/ResourcePresentationTests.swift` |
| `Tests/IntegrationTests/RuntimeTests.swift` | `Tests/Agents/Core/RuntimeTests.swift` |
| `Tests/IntegrationTests/SQLiteDialogLifecycleTests.swift` | `Tests/Storage/Database/SQLiteDialogLifecycleTests.swift` |
| `Tests/IntegrationTests/SQLiteRecordSupport.swift` | `Tests/Storage/Database/SQLiteRecordSupport.swift` |
| `Tests/IntegrationTests/SQLiteRecordTests.swift` | `Tests/Storage/Database/SQLiteRecordTests.swift` |
| `Tests/IntegrationTests/SentenceFunctionTests.swift` | `Tests/Agents/Assistant/SentenceFunctionTests.swift` |
| `Tests/IntegrationTests/SoundSourceTests.swift` | `Tests/Agents/SpeechPerception/SoundSourceTests.swift` |
| `Tests/IntegrationTests/SpeechEnhancementWorkflowTests.swift` | `Tests/Agents/SpeechPerception/SpeechEnhancementWorkflowTests.swift` |
| `Tests/IntegrationTests/SpeechPlaybackTests.swift` | `Tests/Actions/Speech/SpeechPlaybackTests.swift` |
| `Tests/IntegrationTests/SpeechRequestProbe.swift` | `Tests/Agents/Support/SpeechRequestProbe.swift` |
| `Tests/IntegrationTests/StorageContainerTests.swift` | `Tests/Storage/Core/StorageContainerTests.swift` |
| `Tests/IntegrationTests/StorageRepositoryContractTests.swift` | `Tests/Storage/Database/StorageRepositoryContractTests.swift` |
| `Tests/IntegrationTests/StorageRuntimeTests.swift` | `Tests/Storage/Core/StorageRuntimeTests.swift` |
| `Tests/IntegrationTests/StorageSchemaTests.swift` | `Tests/Storage/Database/StorageSchemaTests.swift` |
| `Tests/IntegrationTests/StorageTests.swift` | `Tests/Storage/Core/StorageTests.swift` |
| `Tests/IntegrationTests/UIContainerTests.swift` | `Tests/UI/Container/UIContainerTests.swift` |
| `Tests/IntegrationTests/UIToolTests.swift` | `Tests/Actions/UI/UIToolTests.swift` |
| `Tests/IntegrationTests/UnifiedCapabilityTests.swift` | `Tests/Actions/Contracts/UnifiedCapabilityTests.swift` |
| `Tests/IntegrationTests/VoiceTests.swift` | `Tests/Agents/SpeechPerception/VoiceTests.swift` |
| `Tests/IntegrationTests/WindowGatewayTests.swift` | `Tests/Gateway/Output/WindowGatewayTests.swift` |
| `Tests/IntegrationTests/WorkspaceRepositoryTests.swift` | `Tests/Storage/Database/WorkspaceRepositoryTests.swift` |
| `Tests/IntegrationTests/WriterAgentTests.swift` | `Tests/Agents/Writer/WriterAgentTests.swift` |
| `Tests/IntegrationTests/WriterModelEvaluationTests.swift` | `Tests/Agents/Evaluation/Writer/WriterModelEvaluationTests.swift` |
| `Tests/KokoroTests/KokoroTests.swift` | `Tests/ModelKit/Speech/TTS/Kokoro/KokoroTests.swift` |
| `Tests/KokoroTests/README.md` | `Tests/ModelKit/Speech/TTS/Kokoro/README.md` |
| `Tests/ModelKitAppleSpeechTests/AppleSpeechTests.swift` | `Tests/ModelKit/Speech/Apple/AppleSpeechTests.swift` |
| `Tests/ModelKitAppleSpeechTests/README.md` | `Tests/ModelKit/Speech/Apple/README.md` |
| `Tests/ModelKitDefaultsTests/ChatExecutionTests.swift` | `Tests/ModelKit/Management/Defaults/ChatExecutionTests.swift` |
| `Tests/ModelKitDefaultsTests/D3NativeTests.swift` | `Tests/ModelKit/Management/Defaults/D3NativeTests.swift` |
| `Tests/ModelKitDefaultsTests/DefaultsTests.swift` | `Tests/ModelKit/Management/Defaults/DefaultsTests.swift` |
| `Tests/ModelKitDefaultsTests/README.md` | `Tests/ModelKit/Management/Defaults/README.md` |
| `Tests/ModelKitDefaultsTests/SpeechSelectionTests.swift` | `Tests/ModelKit/Management/Defaults/SpeechSelectionTests.swift` |
| `Tests/ModelKitHubTests/HuggingFaceDownloadTests.swift` | `Tests/ModelKit/Management/Download/HuggingFaceDownloadTests.swift` |
| `Tests/ModelKitHubTests/README.md` | `Tests/ModelKit/Management/Download/README.md` |
| `Tests/ModelKitRuntimeTests/CompositionTests.swift` | `Tests/ModelKit/Management/Runtime/CompositionTests.swift` |
| `Tests/ModelKitRuntimeTests/ModelArtifactTests.swift` | `Tests/ModelKit/Management/Runtime/ModelArtifactTests.swift` |
| `Tests/ModelKitRuntimeTests/ModelLifecycleTests.swift` | `Tests/ModelKit/Management/Runtime/ModelLifecycleTests.swift` |
| `Tests/ModelKitRuntimeTests/README.md` | `Tests/ModelKit/Management/Runtime/README.md` |
| `Tests/ModelKitRuntimeTests/RuntimeBoundaryTests.swift` | `Tests/ModelKit/Management/Runtime/RuntimeBoundaryTests.swift` |
| `Tests/ModelKitTests/AppleChatTests.swift` | `Tests/ModelKit/Language/Apple/AppleChatTests.swift` |
| `Tests/ModelKitTests/CapabilityTests.swift` | `Tests/ModelKit/Core/CapabilityTests.swift` |
| `Tests/ModelKitTests/CoreBoundaryTests.swift` | `Tests/ModelKit/Core/CoreBoundaryTests.swift` |
| `Tests/ModelKitTests/InferenceTaskControlTests.swift` | `Tests/ModelKit/Core/InferenceTaskControlTests.swift` |
| `Tests/ModelKitTests/MultiDecisionTests.swift` | `Tests/ModelKit/Core/MultiDecisionTests.swift` |
| `Tests/ModelKitTests/README.md` | `Tests/ModelKit/Core/README.md` |
| `Tests/ModelKitTests/SessionTests.swift` | `Tests/ModelKit/Core/SessionTests.swift` |
| `Tests/MossNanoTests/MossNanoTests.swift` | `Tests/ModelKit/Speech/TTS/MossNano/MossNanoTests.swift` |
| `Tests/MossNanoTests/README.md` | `Tests/ModelKit/Speech/TTS/MossNano/README.md` |
| `Tests/NemotronTests/NemotronTests.swift` | `Tests/ModelKit/Speech/ASR/NemotronTests.swift` |
| `Tests/NemotronTests/README.md` | `Tests/ModelKit/Speech/ASR/README.md` |
| `Tests/OpenAIChatTests/OpenAIChatTests.swift` | `Tests/ModelKit/Language/OpenAI/OpenAIChatTests.swift` |
| `Tests/OpenAIChatTests/README.md` | `Tests/ModelKit/Language/OpenAI/README.md` |
| `Tests/SileroTests/DeepFilterTests.swift` | `Tests/ModelKit/Speech/Enhancement/DeepFilterTests.swift` |
| `Tests/SileroTests/README.md` | `Tests/ModelKit/Speech/VAD/README.md` |
| `Tests/SileroTests/SileroTests.swift` | `Tests/ModelKit/Speech/VAD/SileroTests.swift` |
| `Tests/SileroTests/WindowedEnhancementTests.swift` | `Tests/ModelKit/Speech/Enhancement/WindowedEnhancementTests.swift` |
| `Tests/UITests/AudioDetectionStateTests.swift` | `Tests/UI/Settings/AudioDetectionStateTests.swift` |
| `Tests/UITests/BluetoothConnectionStateTests.swift` | `Tests/UI/Settings/BluetoothConnectionStateTests.swift` |
| `Tests/UITests/CameraControlAvailabilityTests.swift` | `Tests/UI/Camera/CameraControlAvailabilityTests.swift` |
| `Tests/UITests/CameraFramePresentationTests.swift` | `Tests/UI/Camera/CameraFramePresentationTests.swift` |
| `Tests/UITests/CameraGalleryTests.swift` | `Tests/UI/Camera/CameraGalleryTests.swift` |
| `Tests/UITests/CaptionPresentationTests.swift` | `Tests/UI/Conversation/CaptionPresentationTests.swift` |
| `Tests/UITests/ConversationHistoryPresentationTests.swift` | `Tests/UI/Conversation/ConversationHistoryPresentationTests.swift` |
| `Tests/UITests/ExecutionLogTests.swift` | `Tests/UI/Presentation/ExecutionLogTests.swift` |
| `Tests/UITests/EyeGeometryTests.swift` | `Tests/UI/Presentation/EyeGeometryTests.swift` |
| `Tests/UITests/IslandStateTests.swift` | `Tests/UI/Presentation/IslandStateTests.swift` |
| `Tests/UITests/IslandSystemPresentationTests.swift` | `Tests/UI/Presentation/IslandSystemPresentationTests.swift` |
| `Tests/UITests/ListeningMotionTests.swift` | `Tests/UI/Presentation/ListeningMotionTests.swift` |
| `Tests/UITests/NavigationContextTests.swift` | `Tests/UI/Navigation/NavigationContextTests.swift` |
| `Tests/UITests/PersistentHomeNavigationTests.swift` | `Tests/UI/Navigation/PersistentHomeNavigationTests.swift` |
| `Tests/UITests/README.md` | `Tests/UI/README.md` |
| `Tests/UITests/SettingsStateTests.swift` | `Tests/UI/Settings/SettingsStateTests.swift` |
| `Tests/UITests/UIRequestsTests.swift` | `Tests/UI/Navigation/UIRequestsTests.swift` |
| `Tests/UITests/WebPageTests.swift` | `Tests/UI/Window/WebPageTests.swift` |
| `Tests/UITests/WebSimulatorAcceptance.swift` | `Tests/UI/Window/WebSimulatorAcceptance.swift` |
| `Tests/UITests/WindowStateTests.swift` | `Tests/UI/Window/WindowStateTests.swift` |
| `Tests/UITests/WriterRecordsNativeAcceptance.swift` | `Tests/UI/Window/WriterRecordsNativeAcceptance.swift` |
| `Tests/YOLOPoseTests/CoreMLTensorTransferTests.swift` | `Tests/ModelKit/Vision/CoreMLTensorTransferTests.swift` |
| `Tests/YOLOPoseTests/VisionPerformanceEvaluationTests.swift` | `Tests/ModelKit/Vision/VisionPerformanceEvaluationTests.swift` |
| `Tests/YOLOPoseTests/PoseTests.swift` | `Tests/ModelKit/Vision/PoseTests.swift` |
| `Tests/YOLOPoseTests/README.md` | `Tests/ModelKit/Vision/README.md` |
| `Tests/test_compare_qwen_protocols.py` | `Tests/Agents/Evaluation/Assistant/test_compare_qwen_protocols.py` |
| `Tests/test_evaluate_qwen.py` | `Tests/Agents/Evaluation/Assistant/test_evaluate_qwen.py` |
| `Tests/test_model_download.py` | `scripts/checks/test_model_download.py` |

## 历史实验兼容说明

冻结报告的旧源路径与哈希保留原样；验证旧源码 hash 的严格回放需使用原提交，不能把迁移后的代码冒充原实验源码。当前 runner 与新实验输入使用新路径，具体运行说明见 Decision README。

播放回归主要验证 Actions 的 SpeechPlayback 与 Assistant 合成输出契约，归 Actions/Speech；PlatformKit/Audio 仅保留平台采集和 PCM 转换。

## Xcode 导航

Tests 的 PBXGroup 按新物理目录重建，保留已有文件引用 ID 及所有 build phase/target 成员，仅补齐缺少的测试源、README 和资源导航引用。生产模块分组及用户已有项目设置保留。

## 检查脚本适配

显式测试成员表使 target_sources 的逐候选/逐排除 resolve 重复解析成本显著增加。排除路径先规范化一次为集合，每个候选仅 resolve 一次，以相等或祖先集合交集维持原排除语义；文件、目录及符号链接排除规则不变。

资源操作测试归属检查改为递归扫描 UI 分类，以保留禁止将该工作流测试放入 UI 的原规则。

## 交付结果

职责目录、183 份测试源码的 18 个 target 成员、Xcode 导航、脚本与资源路径已完成迁移。测试断言和业务行为保持；5 个 Simulator scheme 构建通过。完整检查失败与未完成阶段按实际结果记录在 [验证记录](../validation/Tests-Organization.md)，不声称全量测试通过。
