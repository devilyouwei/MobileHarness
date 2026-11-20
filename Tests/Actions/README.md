# Actions tests

函数契约与业务执行。设备/模型/呈现端点的替身不证明原生效果；资源所有权、取消 join、完成语义与错误证据使用生产接口验证。

Contracts：声明与双协议；Execution：装配、组合、资源和观察；NexArm：策略/规划及工作流；Camera、Speech、System、History、UI：各业务能力。

## 测试分层

采用 [Tests 的统一分层](../README.md#测试分层)。混合行表示文件中同时存在独立逻辑单元与真实组件协作；按实际用例边界判断，不按 target 命名判断。

| 能力目录 | 层级 | 文件或用例组 |
| --- | --- | --- |
| Camera | Unit Tests / Integration Tests | [CameraEnhancementTests](Camera/CameraEnhancementTests.swift) |
| Contracts | Unit Tests / Integration Tests | [ActionAuthoringTests](Contracts/ActionAuthoringTests.swift)、[ActionContractTests](Contracts/ActionContractTests.swift) |
| Contracts | Unit Tests | [ActionDeclarationTests](Contracts/ActionDeclarationTests.swift) |
| Contracts/Functions | Unit Tests | [FunctionContractTests](Contracts/Functions/FunctionContractTests.swift) |
| Contracts | Integration Tests | [UnifiedCapabilityTests](Contracts/UnifiedCapabilityTests.swift) |
| Execution | Integration Tests | [ActionCompositionTests](Execution/ActionCompositionTests.swift)、[ActionLifecycleTests](Execution/ActionLifecycleTests.swift)、[ActionObservationTests](Execution/ActionObservationTests.swift)、[ActionsContainerTests](Execution/ActionsContainerTests.swift)、[BehaviorAssemblyTests](Execution/BehaviorAssemblyTests.swift) |
| History | Integration Tests | [HistoryToolTests](History/HistoryToolTests.swift) |
| NexArm | Unit Tests / Integration Tests | [NexArmAimTests](NexArm/NexArmAimTests.swift)、[NexArmArrivalPolicyTests](NexArm/NexArmArrivalPolicyTests.swift)、[NexArmCausalTests](NexArm/NexArmCausalTests.swift)、[NexArmTelemetryTests](NexArm/NexArmTelemetryTests.swift)、[NexArmTests](NexArm/NexArmTests.swift) |
| NexArm | Integration Tests | [NexArmBluetoothIntegrationTests](NexArm/NexArmBluetoothIntegrationTests.swift)、[NexArmSerialAcceptanceTests](NexArm/NexArmSerialAcceptanceTests.swift) |
| NexArm | Unit Tests | [NexArmConnectionPolicyTests](NexArm/NexArmConnectionPolicyTests.swift) |
| Speech | Integration Tests | [SpeechPlaybackTests](Speech/SpeechPlaybackTests.swift) |
| System | Integration Tests | [ProviderDiscoveryTests](System/ProviderDiscoveryTests.swift)、[ResourceInventoryTests](System/ResourceInventoryTests.swift)、[ResourcePreferencesTests](System/ResourcePreferencesTests.swift) |
| System | Unit Tests / Integration Tests | [ProviderSettingsTests](System/ProviderSettingsTests.swift) |
| UI | Integration Tests | [AlbumNavigationTests](UI/AlbumNavigationTests.swift)、[UIToolTests](UI/UIToolTests.swift) |
| UI | Unit Tests / Integration Tests | [FeedbackActionTests](UI/FeedbackActionTests.swift) |

## 执行与替身边界

默认执行 `./scripts/check.sh`；实际期限与原生窗口回归由既有串行阶段隔离。模型/网络/设备开关与原生独立入口见 所属能力 README 和 [执行总索引](../README.md#执行入口)。每次运行单独记录通过、失败与跳过，不将替身结果标成原生验收。

## 辅助代码

[NexArmLegacyArrivalTracker](NexArm/NexArmLegacyArrivalTracker.swift)、[NexArmLegacyDiagnosticController](NexArm/NexArmLegacyDiagnosticController.swift)、[ActionCatalogFixture](Support/ActionCatalogFixture.swift)、[ActionTestRegistry](Support/ActionTestRegistry.swift)、[BehaviorContractFixtures](Support/BehaviorContractFixtures.swift)、[ResolvedCallSupport](Support/ResolvedCallSupport.swift) 提供所属编译目标的夹具、探针或注册，不是独立测试层。

## 能力文档

- [Camera](Camera/README.md)
- [Contracts](Contracts/README.md)
- [Execution](Execution/README.md)
- [History](History/README.md)
- [NexArm](NexArm/README.md)
- [Speech](Speech/README.md)
- [Support](Support/README.md)
- [System](System/README.md)
- [UI](UI/README.md)
