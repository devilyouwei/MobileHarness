# Audio8 验证记录（2026-09-23）

这是 2026-09-23 的历史验证记录。Audio8 adapter 后来从当前源码树移除；当时的取舍见 [ADR 0009](adr/0009-audio8-asr.md)，当前模型选择与验证入口见 [模型资源 README](../MobileHarness/Resources/Models/README.md) 和 [Nemotron 验证记录](Nemotron-Validation.md)。下文关于默认 App 的描述仅反映当时状态。

## 已验证

- 下载官方 iOS 固定 revision 的 20 个模型文件，共 436,741,933 字节；逐文件验证大小及 SHA-256。下载脚本重复执行通过，模型目录忽略 Git。
- Swift 6.4 工具链运行 scripts/check.sh，并启用 HARNESS_TEST_AUDIO8、HARNESS_TEST_SILERO、HARNESS_TEST_NEMOTRON：51 项实际测试通过；1 项可选系统中文 TTS 测试未启用。
- Audio8 真实模型在 Mac 上识别英文 `The quick brown fox jumps over the lazy dog.`，137/4000 点输入分包结果一致；中文得到 `你好，这是一个语音识别测试。`。每句只产生一个 final。
- 验证格式错误在加载前被拒绝、函数分桶、正在推理时取消、30 秒输入上限、卸载后再次加载及空输入完成。未运行用户录音，使用系统合成音频。
- scripts/build-ios.sh 的 App、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAudio8 模拟器构建通过。ModelKitAudio8 generic/platform=iOS 无签名构建通过。
- Core ML 参数扩展保持 Silero CPU-only 默认值；Silero/Nemotron 实际推理及其组合回归通过。

当时编译保留上游 Accelerate CBLAS 调用，所用 SDK 对这些入口给出 deprecated 警告；构建没有错误。该适配器已移除，这项迁移建议不再是当前待办。

## 未验证

未安装到 iPhone；没有麦克风实录、30 秒复杂语音准确率、7 种语言完整质量测试、WER、峰值内存、耗电或热状态结论。不将上游“约 200 MB”的设备数据当成本项目实测。manifest 内存值是预算估值。

模型是整句自回归 ASR，send 不触发声学推理；不能用本测试宣称支持实时 partial。官方完整 iOS 制品不同于 hugging-mac 的 Core ML + PyTorch 混合制品；本项目不需要 PyTorch。

当时的复现流程是先运行 `python3 scripts/download-audio8.py`，再用完整 Xcode 工具链运行 `./scripts/test-audio8.sh`。两个脚本均已随 adapter 移除及后续资源清理而移除，当前仓库不能直接重跑此历史测试；常规 CI 不下载或执行该模型权重。

默认 App 切换验证：scripts/check.sh 通过；真实 Audio8 中英文及取消/重载测试通过；iOS 27 模拟器安装启动成功，界面显示 Audio8 + Silero。模拟器麦克风连续对话与真机运行未验收。
