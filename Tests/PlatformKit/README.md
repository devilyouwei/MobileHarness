# PlatformKit tests

平台事实、音频/图像与底层连接机制。控制业务和连接恢复工作流由 Actions 测试拥有；原生编解码/数据结构集成与真实采集验收分开。

Core：根与状态；Audio：PCM、readiness 和采样；Vision：图像准备；Connectivity：BLE 包、写入准入和连接级预算。

## 测试分层

采用 [Tests 的统一分层](../README.md#测试分层)。混合行表示文件中同时存在独立逻辑单元与真实组件协作；按实际用例边界判断，不按 target 命名判断。

| 能力目录 | 层级 | 文件或用例组 |
| --- | --- | --- |
| Audio | Unit Tests | [AudioCaptureReadinessTests](Audio/AudioCaptureReadinessTests.swift)、[PCMResamplerTests](Audio/PCMResamplerTests.swift) |
| Audio | Unit Tests / Integration Tests | [AudioSampleBufferReaderTests](Audio/AudioSampleBufferReaderTests.swift) |
| Connectivity | Unit Tests | [NexArmBluetoothTests](Connectivity/NexArmBluetoothTests.swift) |
| Core | Integration Tests | [PlatformContainerTests](Core/PlatformContainerTests.swift) |
| Core | Unit Tests / Integration Tests | [PlatformStateTests](Core/PlatformStateTests.swift) |
| Vision | Unit Tests / Integration Tests | [NativeImageCompressionTests](Vision/NativeImageCompressionTests.swift) |

## 执行与替身边界

默认执行 `./scripts/check.sh`；实际期限与原生窗口回归由既有串行阶段隔离。模型/网络/设备开关与原生独立入口见 所属能力 README 和 [执行总索引](../README.md#执行入口)。每次运行单独记录通过、失败与跳过，不将替身结果标成原生验收。

## 能力文档

- [Audio](Audio/README.md)
- [Connectivity](Connectivity/README.md)
- [Core](Core/README.md)
- [Vision](Vision/README.md)

连接业务与 Agent/Gateway/Actions 的回归归 [NexArmBluetoothIntegrationTests](../Actions/NexArm/NexArmBluetoothIntegrationTests.swift)，不在基础平台目录承载上层工作流。默认测试不创建真实 CoreBluetooth manager。
