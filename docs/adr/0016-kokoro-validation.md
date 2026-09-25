# ADR 0016 — Kokoro CoreAI 独立验证

2026-09-24，用户选择 mlboydaisuke/Kokoro-82M-CoreAI 先验证本地 TTS。

增加 ModelKitKokoro → ModelKit / ModelKitCoreAI，沿用 SpeechSynthesisCapability 和现有图后端；不引入完整 coreai-kit 或业务依赖。固定模型 revision、代码来源、SHA-256 和 Apache/BSD 许可。只下载 af_heart 与必要运行资源，权重不入 Git。

该导出只有 US English 词典，尚不具备中文或日文前处理。当前 Agent 中文对话不切换，使用 KokoroValidation scheme 进入独立真机验证页面；此入口只测试 capability，不产生 Agent 输入/输出。验证通过不表示多语言能力验收，也不改变双网关契约。

CPU-only 执行 predictor/prosody/vocoder，Swift 执行 alignment/STFT。队列与音频预算见 adapter README；无等待 admission，过载明确失败。token 超限按词分块，frame 超限失败，取消在图调用边界检查，unload 等待 lease。无运行时模型下载、无系统语音回退。

模型卡只提供 Mac 性能数字；iOS 真机兼容性、语音质量、常驻内存和热状态必须实测。KokoroValidation 使用 Release，并区分 load、首段 PCM、总合成时间与音频时长。应用默认路径不加载此模型。
