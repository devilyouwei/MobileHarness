# ADR 0009 Audio8 原生 ASR adapter

> Historical scope: Historical adapter decision. Audio8 was removed from the current source tree; this record does not describe an available provider. See the [validation history](../validation/Audio8-Validation.md).

状态：已实施，独立能力；未切换 App；iPhone 运行待验收。日期：2026-09-23。

用户要求参考 hugging-mac/models/audio8_asr 添加模型。该参考的 audio tower 为 Core ML，decoder 为 PyTorch/MPS。为支持 iOS，本项目采用官方 Audio8-ASR-0.1B-iOS-ANE 固定提交 6a3f52c400cd436e1bd32c0514758345ddf14bfa，复用其 Swift 算法并适配现有能力、资源与并发边界。模型及官方 SDK 为 CC-BY-NC-4.0，保留许可和来源，不视作可无限制商用制品。

ModelKitAudio8 → ModelKit / ModelKitCoreML / ModelKitONNX。新增唯一具体依赖 Microsoft ONNX Runtime Swift Package 1.24.2，为官方 int4 decoder 提供原生运行时；不引入 Python、远程执行或第三方 LLM 框架。纯 ModelKit 保持无项目内依赖。CoreMLGraph 新增可选函数名和计算设备配置，Silero 仍默认 CPU-only，Audio8 选择 CPU + Neural Engine。

所有 Core ML 对象保留在后端 actor；ONNXGraph/ONNXTensor 是不跨 actor 的非 Sendable 对象，由 Audio8Engine 独占。循环状态、mask、pooling、projector、tokenizer 与生成策略属于模型子目录，不进入通用后端。去除原 SDK 的无界串行任务队列和 unchecked Sendable 声明。

外部沿用 SpeechRecognitionCapability。Audio8 是最长 30 秒整句识别，接口支持分包输入但 finishInput 后才产生唯一 final；不伪装为流式 partial。音频、token、输出队列均有上限，超限报错而非截断。取消在系统调用/解码步边界检查，待推理退出才释放 lease。

App 仍使用 Silero + Nemotron + 系统 TTS；Audio8 为单独 product，不加入 HarnessKit 聚合产品或模型打包脚本。装配层将来可切换，Gateway、Agent、能力协议无需改变。制品只下载到忽略 Git 的 artifacts，并保留可复现下载与 SHA-256 清单。

后续：用户已授权切换默认 App，当前装配见 [ADR 0010](0010-audio8-app-binding.md)；上面的未绑定描述为初始状态。
