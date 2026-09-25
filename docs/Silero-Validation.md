# Silero 验证记录（2026-09-23）

参考实现与当前契约见 [Silero README](../MobileHarness/ModelKit/Speech/VAD/Silero/README.md) 和 [ADR 0008](adr/0008-silero-vad.md)。

在完整 Xcode 工具链下，设置 HARNESS_TEST_SILERO=1 与 HARNESS_TEST_NEMOTRON=1 运行 scripts/check.sh：48 项实际测试通过；可选系统中文 TTS 测试本轮未启用。包含真实 Silero 的静音/合成语音、512/137/4000 点分片逐条结果一致、重置、尾部补零、取消和再次使用。额外验证 VAD capability 可独立注册与解析；边界策略使用概率而非输入振幅，长语句有界；16/44.1/48 kHz 连续重采样保持滤波器状态。

真实组合测试以 137 点分包将“前导静音 + 英文合成语音 + 尾部静音”送入 Silero 与 Gateway 分段器，得到一个完整语句，再送入真实 Nemotron，得到 `The quick brown fox jumps over the lazy dog`。不使用用户录音，不需要麦克风权限。

App/ModelKitRuntime/ModelKitNemotron/ModelKitSilero 模拟器构建通过；MobileHarness generic/platform=iOS 无签名构建通过。实际 App 内存在 Models/Silero 模型、manifest 和 MIT 许可，打包文件按 SHA-256 核验。

尚未在 iPhone 上运行。没有自然语音 WER、VAD F1、噪声误报/漏报、20 轮连续麦克风对话、峰值内存、延迟、耗电或热状态的验收结论。完整 App 仍需要 Nemotron 支持的 iOS 27/h18p，Silero 自身的基线更低。

复现：先运行 scripts/download-silero.py（组合测试还需 download-nemotron.py），再使用完整 Xcode 工具链执行 `HARNESS_TEST_NEMOTRON=1 ./scripts/test-silero.sh`。不设置 Nemotron 环境开关时只测试 Silero。
