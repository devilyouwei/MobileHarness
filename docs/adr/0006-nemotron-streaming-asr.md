# ADR 0006 Nemotron 流式 ASR 与模型层目录纠正

状态：已实施，未接入应用 pipeline，iOS 真机运行待验收。日期：2026-09-23。

按 Tech_Design.md 第 11、16 节，注册绑定由 Runtime/Bindings 移至 Management；Apple 实现移至 Speech/ASR/Apple、Speech/TTS/Apple 与 Speech/Shared/Apple。Runtime 只容纳推理后端，本次实现 CoreAI。此决策修正 ADR 0005 的模型层归档，不改变独立 SDK、能力注入和模块无环约束。

首个下载制品为用户指定 Nemotron-3.5-ASR-Streaming-CoreAI。固定 Hugging Face revision 和全部文件 SHA-256，下载到 Resources/Models/artifacts 并忽略 Git；不自动打包数 GB 权重。模型能力在 Speech/ASR/Nemotron，通过独立 ModelKitNemotron target 实现 SpeechRecognitionCapability；AppContainer 和双 Gateway 未接入该实现。

使用已转换的六图 CoreAI 制品，不嵌入 Python。前处理为连续 16 kHz log-mel；保留跨块缓存与 RNNT 状态，send 时输出 partial，finishInput 刷新 tail 并输出 final。按 actor 隔离 session，避免主线程推理及 unchecked Sendable。

Core 实现当前单模型所需的 ModelManifest、ModelRegistry、ModelManager 和 InferenceScheduler：校验资源、独占 lease、加载复用、等待卸载、忙时拒绝。每个 provider 只有一个会话/操作，输入/输出/token/时长均有上限。没有实现多个模型间优先级、公平性或实际内存/热指标调度；不将最小 admission 实现描述成完整调度器。

CoreAI 需要 iOS/macOS 27。模拟器 SDK 缺失 CoreAI 时明确不可用；当前 iOS Conformer AOT 仅允许 h18p 架构，不对未知设备尝试错误制品或退到云端。Mac 实际推理与 iOS 设备编译分别记录，不能用模拟器构建代替真机验收。
