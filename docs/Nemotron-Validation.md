# Nemotron 接入验证（2026-09-23）

模型与制品固定版本、接口和资源上限见 [模型 README](../MobileHarness/ModelKit/Speech/ASR/Nemotron/README.md)，架构取舍见 [ADR 0006](adr/0006-nemotron-streaming-asr.md)。本次仅实现独立 capability，未注入 App/Gateway pipeline。

## 已执行

- 下载并再次完整验证 56 个文件，共 2,670,571,591 字节；每个文件校验大小和 SHA-256。模型权重目录已忽略 Git。
- 使用完整 Xcode 工具链，设置 `HARNESS_TEST_NEMOTRON=1` 运行 `./scripts/check.sh`：格式检查、41 个实际执行测试通过；另有 1 个可选系统中文 TTS 测试未启用。
- `./scripts/build-ios.sh`：App、ModelKitRuntime、ModelKitNemotron 模拟器构建通过。
- ModelKitNemotron 的 `generic/platform=iOS`、禁用签名构建通过，覆盖真机 SDK 下的 CoreAI 实现。
- 在当前 Mac CoreAI GPU 上运行实际权重，输入由系统 TTS 生成的固定 16 kHz 单声道样本，无麦克风权限或用户录音需求。

英文分别以 137、4,000、16,000 个采样点分片输入，三次均得到 `The quick brown fox jumps over the lazy dog`；中文得到 `你好, 这是一个语音识别测试`。测试同时检查 partial/final、segment 与 revision、预热、连续会话、取消、空输入、卸载和再次加载。纯单元测试覆盖 mel 分片一致性、tokenizer、独占 lease、制品损坏及路径穿越拒绝。

复现真实推理：先运行 `python3 scripts/download-nemotron.py`，再使用完整 Xcode 工具链运行 `./scripts/test-nemotron.sh`。常规 CI 不自动启用真实权重测试。

## 未覆盖

尚未在 iPhone 运行；iOS 制品中的 Conformer 只提供 h18p 架构，入口会拒绝其他架构。需要 iOS/macOS 27 CoreAI；当前模拟器 SDK 不含 CoreAI，模拟器构建只验证不可用分支，不代表可推理。

本次不是自然语音 WER、长时间稳定性、延迟、峰值内存、耗电或热表现基准。manifest 的内存预算为估值。真实手机安装与模型分发、全局多模型调度，以及接入麦克风/VAD/Gateway 均待后续实施。

## App 切换后的追加验证

按用户后续要求，App 已通过 capability 使用 Nemotron ASR（ADR 0007），原先“未接入 pipeline”的记录描述此前独立模型阶段。

切换后重新运行 `./scripts/check.sh`：42 项实际测试通过；真实模型和系统 TTS 两项可选测试本轮未启用。新增测试验证 16/44.1/48 kHz 输入转换后的时长、幅度、分包序号，以及输入格式中途变化的拒绝行为。

`./scripts/build-ios.sh` 三个 scheme 均通过；MobileHarness 的 generic/platform=iOS 无签名构建通过。检查实际 App 的 Models 目录，32 个 iOS 制品逐一通过 manifest 的大小与 SHA-256 校验，约 1.2 GB；未打包 macos 制品。真机与模拟器使用独立输入输出文件清单，模拟器不依赖权重文件。

尚未安装到 iPhone，麦克风 → Nemotron → 固定回复 → 扬声器的完整实机验收仍未完成。
