# ADR 0008 Silero VAD capability 与输入分段

状态：已实施；iPhone 麦克风实测待验收。日期：2026-09-23。

用户要求参考 hugging-mac Silero 实现。实际源码位于该仓库 packages/hugging_mac_sdk/src/hugging_mac_sdk/models/silero，参考提交 60b176843703fd730a04e2b537212fba92b399a3。选择同一 Silero v6.2.1 Core ML 32 ms 制品，固定 revision 和逐文件 SHA-256；保留上游模型 MIT 与参考实现 MIT 许可。未引入 Python/ONNX 运行时。

ModelKit/Speech/VAD/VoiceActivityCapability.swift 定义独立能力：输入 PCM，通过会话返回连续采样范围的语音概率。消费层不接收模型名、运行时对象或权重路径。ModelKitRuntime 增加 voiceActivity 注册/解析；可单独组合，不强制所有 VoiceCapabilities 消费者引入 VAD。

Speech/VAD/Silero 独立 target 负责 512 点窗口、64 点上下文、显式 h/c 状态；Backends/CoreML 独立 target 负责张量桥接和 Core ML 执行。每个 provider 最多一个 session，process 采用 await 背压、每次至多 16,000 点/32 个结果，残留缓存小于 512 点；取消等待单次推理完成后释放 lease，finish 只将真实尾部长度计入结果，reset 清空所有状态。

App 将 VoiceActivityCapability 注入 Gateway 的 VoiceActivitySegmenter。PlatformKit 连续重采样后才送 VAD，避免每个采集分片重置滤波器。网关将概率范围对应回有界 PCM，连续概率达到阈值 96 ms 后确认说话，800 ms 静音后结束，前导约 0.2 秒、语句最长约 12 秒。阈值默认 0.5。该策略参考 Python 流式实现；没有混用离线后处理的 threshold−0.15 算法。

已有能量 VoiceSegmenter 保留但 App 不再调用。Nemotron ASR、固定回复和系统 TTS 不变，仍是轮流对话：识别/播放期间不接收新句。暂停期重置 VAD、重采样和边界状态，防止回复回声或旧状态影响下一轮。没有实现全双工/回声消除、抢话或边说边 ASR 字幕。

Core ML 当前使用 CPU-only，避免与 Nemotron 的 GPU 路径争用；这是配置选择，不是手机性能结论。Silero 自身可在项目 iOS 18 基线执行，完整 App 仍受 Nemotron iOS 27/h18p 制品限制。构建脚本将 Silero 及其 manifest/许可打包到 Models/Silero；模拟器不要求下载权重。
