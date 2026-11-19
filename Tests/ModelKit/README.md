# ModelKit tests

独立推理 SDK、模型管理和适配。默认回归不加载真实权重；实际 HTTP framing、文件、Core ML 张量和 provider/manager 协作属于集成范围。

Core：会话与输入契约；Management：选择、并发、制品和下载；Language、Speech、Vision：适配与算法。

## 测试分层

采用 [Tests 的统一分层](../README.md#测试分层)。混合行表示文件中同时存在独立逻辑单元与真实组件协作；按实际用例边界判断，不按 target 命名判断。

| 能力目录 | 层级 | 文件或用例组 |
| --- | --- | --- |
| Core | Unit Tests | [CapabilityTests](Core/CapabilityTests.swift)、[CoreBoundaryTests](Core/CoreBoundaryTests.swift)、[InferenceTaskControlTests](Core/InferenceTaskControlTests.swift)、[MultiDecisionTests](Core/MultiDecisionTests.swift)、[SessionTests](Core/SessionTests.swift) |
| Core | Integration Tests | [DecisionWeightArchiveTests](Core/DecisionWeightArchiveTests.swift) |
| Language/Apple | Unit Tests | [AppleChatTests](Language/Apple/AppleChatTests.swift) |
| Language/Gemma4 | Unit Tests / Integration Tests | [Gemma4Tests](Language/Gemma4/Gemma4Tests.swift) |
| Language/Gemma4 | Unit Tests / Integration Tests | [GemmaToolProtocolTests](Language/Gemma4/GemmaToolProtocolTests.swift) |
| Language/OpenAI | Unit Tests / Integration Tests | [OpenAIChatTests](Language/OpenAI/OpenAIChatTests.swift) |
| Management/Defaults | Integration Tests | [ChatExecutionTests](Management/Defaults/ChatExecutionTests.swift)、[D3NativeTests](Management/Defaults/D3NativeTests.swift)、[DefaultsTests](Management/Defaults/DefaultsTests.swift)、[SpeechSelectionTests](Management/Defaults/SpeechSelectionTests.swift) |
| Management/Defaults | Unit Tests / Integration Tests | [DecisionAdapterNativeTests](Management/Defaults/DecisionAdapterNativeTests.swift) |
| Management/Download | Unit Tests / Integration Tests | [HuggingFaceDownloadTests](Management/Download/HuggingFaceDownloadTests.swift) |
| Management/Runtime | Integration Tests | [CompositionTests](Management/Runtime/CompositionTests.swift)、[ModelLifecycleTests](Management/Runtime/ModelLifecycleTests.swift)、[RuntimeBoundaryTests](Management/Runtime/RuntimeBoundaryTests.swift) |
| Management/Runtime | Unit Tests / Integration Tests | [ModelArtifactTests](Management/Runtime/ModelArtifactTests.swift) |
| Speech/ASR | Unit Tests / Integration Tests | [NemotronTests](Speech/ASR/NemotronTests.swift) |
| Speech/Apple | Unit Tests / Integration Tests | [AppleSpeechTests](Speech/Apple/AppleSpeechTests.swift) |
| Speech/Enhancement | Unit Tests / Integration Tests | [DeepFilterTests](Speech/Enhancement/DeepFilterTests.swift)、[WindowedEnhancementTests](Speech/Enhancement/WindowedEnhancementTests.swift) |
| Speech/TTS/Kokoro | Unit Tests / Integration Tests | [KokoroTests](Speech/TTS/Kokoro/KokoroTests.swift) |
| Speech/TTS/MossNano | Unit Tests / Integration Tests | [MossNanoTests](Speech/TTS/MossNano/MossNanoTests.swift) |
| Speech/VAD/Energy | Unit Tests | [EnergyVADTests](Speech/VAD/Energy/EnergyVADTests.swift) |
| Speech/VAD | Unit Tests / Integration Tests | [SileroTests](Speech/VAD/SileroTests.swift) |
| Vision | Integration Tests | [CoreMLTensorTransferTests](Vision/CoreMLTensorTransferTests.swift) |
| Vision | Unit Tests / Integration Tests | [PoseTests](Vision/PoseTests.swift) |

## 执行与替身边界

默认执行 `./scripts/check.sh`；实际期限与原生窗口回归由既有串行阶段隔离。模型/网络/设备开关与原生独立入口见 所属能力 README 和 [执行总索引](../README.md#执行入口)。每次运行单独记录通过、失败与跳过，不将替身结果标成原生验收。

## 能力文档

- [Core](Core/README.md)
- [Language](Language/README.md)
- [Management](Management/README.md)
- [Speech](Speech/README.md)
- [Vision](Vision/README.md)
