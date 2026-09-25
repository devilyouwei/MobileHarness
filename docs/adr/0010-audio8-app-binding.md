# ADR 0010 默认语音切换为 Audio8 + Silero

状态：已实施。日期：2026-09-23。

用户要求先在模拟器调试语音，当前模拟器 SDK 不包含 CoreAI。AppContainer 改为构造 Audio8ASR；Silero VAD、Apple TTS 和固定回复保持原有职责。录音前 warmup 校验固定制品并预加载 5 秒函数。Gateway、Agent 继续依赖 capability，运行时契约不变。

HarnessKit 聚合产品改为包含 ModelKitAudio8；Nemotron 保留独立产品和下载制品。默认 App 不再打包 Nemotron。scripts/stage-voice-models.sh 在模拟器、真机均复制 Audio8/Silero、清单及许可，Config/Voice-Models 文件列表显式声明输入输出。权重不入 Git，不在运行时下载。

Audio8 是整句识别：Silero 停顿约 0.8 秒或达到 12 秒上限后提交，finishInput 后给出 final，不提供实时 partial。录音、识别、固定回复、TTS 仍轮流执行。最低 iOS 18；手机性能待实测。保留 CC-BY-NC-4.0 许可及来源。
