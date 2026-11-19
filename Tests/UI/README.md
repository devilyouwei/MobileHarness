# UI tests

呈现状态、布局及原生组件集成。UI 目录不等于 UI 自动化；仅 WriterRecordsUITests 使用 XCUIAutomation 操作实际 App。

Camera、Conversation、Navigation、Presentation、Settings、Window：各呈现能力；Container：根和跨模块活动呈现。

## 测试分层

采用 [Tests 的统一分层](../README.md#测试分层)。混合行表示文件中同时存在独立逻辑单元与真实组件协作；按实际用例边界判断，不按 target 命名判断。

| 能力目录 | 层级 | 文件或用例组 |
| --- | --- | --- |
| Camera | Unit Tests | [CameraControlAvailabilityTests](Camera/CameraControlAvailabilityTests.swift)、[CameraGalleryTests](Camera/CameraGalleryTests.swift) |
| Camera | Unit Tests / Integration Tests | [CameraFramePresentationTests](Camera/CameraFramePresentationTests.swift) |
| Container | Integration Tests | [IslandIntegrationTests](Container/IslandIntegrationTests.swift)、[UIContainerTests](Container/UIContainerTests.swift) |
| Conversation | Unit Tests / Integration Tests | [CaptionPresentationTests](Conversation/CaptionPresentationTests.swift) |
| Conversation | Unit Tests | [ConversationHistoryPresentationTests](Conversation/ConversationHistoryPresentationTests.swift) |
| Navigation | Integration Tests | [PersistentHomeNavigationTests](Navigation/PersistentHomeNavigationTests.swift) |
| Navigation | Unit Tests | [NavigationContextTests](Navigation/NavigationContextTests.swift)、[UIRequestsTests](Navigation/UIRequestsTests.swift) |
| Presentation | Unit Tests / Integration Tests | [IslandSystemPresentationTests](Presentation/IslandSystemPresentationTests.swift) |
| Presentation | Unit Tests | [ExecutionLogTests](Presentation/ExecutionLogTests.swift)、[EyeGeometryTests](Presentation/EyeGeometryTests.swift)、[IslandStateTests](Presentation/IslandStateTests.swift)、[ListeningMotionTests](Presentation/ListeningMotionTests.swift) |
| Settings | Unit Tests | [AudioDetectionStateTests](Settings/AudioDetectionStateTests.swift)、[BluetoothConnectionStateTests](Settings/BluetoothConnectionStateTests.swift)、[SettingsStateTests](Settings/SettingsStateTests.swift) |
| Window | Unit Tests / Integration Tests | [WebPageTests](Window/WebPageTests.swift) |
| Window | Integration Tests | [WebSimulatorAcceptance](Window/WebSimulatorAcceptance.swift) |
| Window | Unit Tests | [WindowStateTests](Window/WindowStateTests.swift) |
| Window | UI Tests | [WriterRecordsUITests](Window/WriterRecordsUITests.swift) |

## 执行与替身边界

默认执行 `./scripts/check.sh`；实际期限与原生窗口回归由既有串行阶段隔离。模型/网络/设备开关与原生独立入口见 所属能力 README 和 [执行总索引](../README.md#执行入口)。每次运行单独记录通过、失败与跳过，不将替身结果标成原生验收。

## 能力文档

- [Camera](Camera/README.md)
- [Container](Container/README.md)
- [Conversation](Conversation/README.md)
- [Navigation](Navigation/README.md)
- [Presentation](Presentation/README.md)
- [Settings](Settings/README.md)
- [Window](Window/README.md)

WriterRecordsUITests 由 `WRITER_UI_ACCEPTANCE` 条件和独立 simulator 脚本启用。WebSimulatorAcceptance 是调用生产 WebPageContainer/WebPageView 的原生集成宿主，不是完整应用 E2E。UITests 编译 target 仍只依赖 UI；UIContainer/Island 跨模块用例仍在原 IntegrationTests target。
