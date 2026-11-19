# App tests

应用装配、宿主生命周期及应用接线。真实生产根验收与手工服务图分别验证；直接调用工作流并注入协作者的用例不称 UI 自动化。

Composition：根注册和装配；Lifecycle：启动/回滚/环境；Settings、Resources、Presentation、Speech、Camera、Web：所属应用接线。

## 测试分层

采用 [Tests 的统一分层](../README.md#测试分层)。混合行表示文件中同时存在独立逻辑单元与真实组件协作；按实际用例边界判断，不按 target 命名判断。

| 能力目录 | 层级 | 文件或用例组 |
| --- | --- | --- |
| Camera | Unit Tests | [CameraVisionRestartTests](Camera/CameraVisionRestartTests.swift)、[PhotoDispositionWorkflowTests](Camera/PhotoDispositionWorkflowTests.swift) |
| Composition | Unit Tests | [FoundationFailureTests](Composition/FoundationFailureTests.swift) |
| Composition | Integration Tests | [ProductionCompositionAcceptance](Composition/ProductionCompositionAcceptance.swift)、[RootCompositionTests](Composition/RootCompositionTests.swift) |
| Lifecycle | Unit Tests | [ApplicationEnvironmentInputsTests](Lifecycle/ApplicationEnvironmentInputsTests.swift) |
| Lifecycle | Unit Tests / Integration Tests | [ApplicationLifecycleTests](Lifecycle/ApplicationLifecycleTests.swift) |
| Lifecycle | Integration Tests | [IndependentOutputTests](Lifecycle/IndependentOutputTests.swift) |
| Presentation | Unit Tests | [ActionActivityTests](Presentation/ActionActivityTests.swift)、[HomeEffectsTests](Presentation/HomeEffectsTests.swift)、[NativeInteractionWorkflowTests](Presentation/NativeInteractionWorkflowTests.swift) |
| Presentation | Unit Tests / Integration Tests | [ConversationHistoryWorkflowTests](Presentation/ConversationHistoryWorkflowTests.swift)、[ConversationPresentationTests](Presentation/ConversationPresentationTests.swift) |
| Presentation | Integration Tests | [WindowExecutionTests](Presentation/WindowExecutionTests.swift) |
| Resources | Unit Tests / Integration Tests | [ModelResourceInteractionWorkflowTests](Resources/ModelResourceInteractionWorkflowTests.swift) |
| Resources | Integration Tests | [ModelResourcesWorkflowTests](Resources/ModelResourcesWorkflowTests.swift)、[ResourceObservationWorkflowTests](Resources/ResourceObservationWorkflowTests.swift) |
| Settings | Unit Tests / Integration Tests | [SettingsInteractionTests](Settings/SettingsInteractionTests.swift) |
| Settings | Unit Tests | [SettingsTransactionTests](Settings/SettingsTransactionTests.swift) |
| Speech | Unit Tests / Integration Tests | [AudioDetectionWorkflowTests](Speech/AudioDetectionWorkflowTests.swift)、[ListeningCaptureWorkflowTests](Speech/ListeningCaptureWorkflowTests.swift) |
| Speech | Integration Tests | [ListeningActivationTests](Speech/ListeningActivationTests.swift) |
| Web | Unit Tests / Integration Tests | [WebWorkspaceTests](Web/WebWorkspaceTests.swift) |

## 执行与替身边界

默认执行 `./scripts/check.sh`；实际期限与原生窗口回归由既有串行阶段隔离。模型/网络/设备开关与原生独立入口见 所属能力 README 和 [执行总索引](../README.md#执行入口)。每次运行单独记录通过、失败与跳过，不将替身结果标成原生验收。

## 能力文档

- [Camera](Camera/README.md)
- [Composition](Composition/README.md)
- [Lifecycle](Lifecycle/README.md)
- [Presentation](Presentation/README.md)
- [Resources](Resources/README.md)
- [Settings](Settings/README.md)
- [Speech](Speech/README.md)
- [Web](Web/README.md)

ProductionCompositionAcceptance 使用生产 ServiceFactories/ModuleRegistration/AppComposition；独立 `scripts/simulator/test-composition.sh` 验证设置请求与生命周期，不请求真实模型，也不进行 UI 点击。
