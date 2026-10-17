# Tests

## 职责与边界

测试源统一位于本目录，由根 Package.swift 的独立 target 编译。单元/合成集成测试验证协议、状态及失败契约；真实模型、网络、原生 UI 和物理设备使用各自显式 gate，不能用替身通过代替验收。每次执行的环境、数字、失败和日志只记录到 [validation](../docs/validation/README.md)。

## 当前测试分工

| 目录 | 测试职责 |
| --- | --- |
| [IntegrationTests](IntegrationTests/README.md) | Agents/Gateway/Actions/Storage 真实边界与注入执行/模型替身 |
| [AppWorkflowTests](AppWorkflowTests/README.md) | 根生命周期、Feature workflows、独立输出与 UI 数据映射 |
| [UITests](UITests/README.md) | UI-owned 状态、分页、布局值和交互；不是原生触摸自动化 |
| [FunctionContractTests](FunctionContractTests/README.md) | 中立函数定义、参数、预算及结果 |
| [ModelKitTests](ModelKitTests/README.md) | 基础推理 SDK 的类型、流及并发契约 |
| [ModelKitDefaultsTests](ModelKitDefaultsTests/README.md) | 模型选择、缺失资源与默认组装 |
| [ModelKitRuntimeTests](ModelKitRuntimeTests/README.md) | 管理器注册、准备、卸载与替换 |
| [ModelKitHubTests](ModelKitHubTests/README.md) | 下载/制品、安全边界、可选真实网络传输 |
| [ModelKitAppleSpeechTests](ModelKitAppleSpeechTests/README.md) | Apple 音频请求与 PCM 转换 |
| [OpenAIChatTests](OpenAIChatTests/README.md) | 请求编码、Responses SSE、原生调用配对与取消 |
| [Gemma4Tests](Gemma4Tests/README.md) | 本地语言适配契约和显式启用的真实推理 |
| [NemotronTests](NemotronTests/README.md) / [SileroTests](SileroTests/README.md) | ASR/VAD 模型适配 |
| [EnergyVADTests](EnergyVADTests/README.md) | 纯 RMS/hysteresis、分包边界与复位 |
| [MossNanoTests](MossNanoTests/README.md) / [KokoroTests](KokoroTests/README.md) | TTS 适配、PCM 和显式真实模型检查 |
| [YOLOPoseTests](YOLOPoseTests/README.md) | RGB、预处理、解码、NMS、pose 和可选模型 smoke |
| [AgentModelEvaluationTests](AgentModelEvaluationTests/README.md) | 与 SDK 测试分离的应用提示词实验 |
| test_model_download.py | 离线下载清单、安全路径、ZIP 校验和原子替换 |

## 运行与用例设计

常规入口为 ../scripts/check.sh；配置完整 Xcode 后按单个 target/函数过滤 swift test 可复现专项。真实网络、模型及设备 gate 见所属 README，不在普通检查中自动启用，不提交凭据、权重或用户媒体。

异步测试用明确 gate/确认信号控制顺序，检查可观察行为、失败、隔离、取消与清理；注入的执行者和数据必须明确标为合成。构建成功、协议测试通过与原生/物理验收分别报告。

## 待实现

- 各模型及设备 README 列出的真实准确率、持续运行、声学/图像质量和资源压力验收。
- 原生 UI 导航、手势、辅助功能及长历史交互验收。

## Storage 依赖

✅ 存储访问使用独立的 State、Cache、Database 和 Files 接口；App 注册根实例，消费者通过构造器获得所需能力。存储容器不接管本目录的业务验证、执行和完成语义。

## 公开 State 边界

✅ State 回归覆盖公开编码、作用域隔离、代际/容量/失败、Task 投影与每轮请求。Assistant fixture 显式注入隔离的公开事实源；测试替身和自动化结果不等于真实模型或物理设备验收。

[公开 State 契约](../MobileHarness/Storage/State/README.md)
