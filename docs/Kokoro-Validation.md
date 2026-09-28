# Kokoro 验证记录

历史默认：FluidAudio Core ML 中英双语；已因反复真机闪退由 MOSS 替换，见 ADR 0058 与 Moss-Validation.md。下面 CoreAI / 英语单语数据为历史记录，不能代表当前模型的结果。

## 历史 CoreAI 验证

日期：2026-09-24。指定模型：[mlboydaisuke/Kokoro-82M-CoreAI](https://huggingface.co/mlboydaisuke/Kokoro-82M-CoreAI)，固定 revision `b869e4ceed2e99dba3491f613403ac2240505250`。

## 范围

独立 `ModelKitKokoro` capability 和 `KokoroValidation` 真机入口。2026-09-28 起默认合成绑定已切换为 Kokoro，Assistant 以简短美式英语回复；下列 2026-09-24 指标保留为历史记录。模型图、US 词典、af_heart 和 DSP 数据合计 346,431,925 bytes；只下载推理需要的音色，均带 SHA-256，不入 Git。Swift 宿主代码来源 coreai-kit `7d5403e6e5d75a6f204814e56bbe342034744746`，复用现有 CoreAI 后端。

仅支持 `en` / `en-US` 和 `af_heart`。此导出不具备中文、日文前处理；不支持的 locale 或字符直接拒绝。英语生词可能按字母拼读，多音词采用词典默认读法，小数需先写为英文文字。不能把原始 Kokoro 的多语言列表视为此适配器已经支持的范围。

## 已验证

- Mac / macOS 27 / Release / CPU-only，真实三图推理输出 24 kHz mono Float32 PCM。
- 固定文本：`The quick brown fox jumps over the lazy dog.`
- 首次加载与编译 69.57 秒，生成音频 3.375 秒。
- 两次首段 PCM：1.322 / 1.332 秒；总合成：1.322 / 1.333 秒，实时率约 0.39。
- 非空/有限且非静音音频、序列号、时间戳、唯一 finished、并发拒绝、取消与卸载通过。
- 无权重测试覆盖语言/字符拒绝、长度分块不丢词、词典优先级/整数转换，以及 duration 对齐、ties-to-even 舍入、NaN/超长拒绝。
- 根 `scripts/check.sh` 通过，`scripts/build-ios.sh` 五个模拟器 scheme 构建通过。iOS 真机 Release 签名构建通过。
- 最终 Mac 重跑（已缓存编译）：加载 0.337 秒，两次首段 1.505 / 1.036 秒，音频仍为 3.375 秒。不同运行有波动，非统计性性能基准。
- 已连接 iPhone 17 Pro，但两次安装分别因远端连接中断、连接后立即断开失败；未获得真机推理结果，不能宣称手机运行成功。

以上 Mac 数字不是 iPhone 性能。没有进行与 PyTorch 的独立频谱比对；上游模型卡的谱相关度结果不当作本适配器验收结果。样例音频由固定测试文本生成，位于 `/tmp/mobileharness-kokoro-0.wav` 和 `/tmp/mobileharness-kokoro-1.wav`。

## 复现

1. `python3 scripts/download-kokoro.py`，可重复运行校验本地文件。
2. Mac 使用匹配 Xcode 27：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/test-kokoro.sh`。
3. Xcode 选择 **KokoroValidation** scheme、iOS 27 真机，默认 Release。沿用项目本地签名设置。
4. 点击“合成并试听”；显示加载、首段 PCM、总合成时间、音频时长、实时率与系统热状态。再次点击可测已加载状态。
5. 点击“停止并卸载”会取消推理/播放并等待模型释放。暂存音频仅在临时目录，停止时清理。

自动设备验证可传 `-kokoro-benchmark -kokoro-autorun`；只生成固定句子，不启麦克风或扬声器，结果写入 App Documents/kokoro-validation.txt。此入口直接验证能力，不驱动 Agent，也不改变正常语音网关路径。

## 尚需验收

人工试听自然度、英文生词/人名/多音词、长句分块衔接；在真机用 Instruments 测量常驻与峰值内存、连续 5–10 分钟合成时的热状态和延迟变化。当前 UI 的热状态仅为系统分级，并非温度测量。长句超过 512 frame 会明确失败，不截断尾音。首次图编译和无法被取消抢占的单次系统图执行可能增加等待时间。

## 默认替换复验（2026-09-28）

- ✅ 本地固定 Kokoro 下载配置重新校验通过，无新增依赖或提交权重。
- ✅ Xcode 27.0 (27A266a) / Swift 6.4；通过 DEVELOPER_DIR 选择完整 Xcode，未修改系统工具选择。
- ✅ `scripts/check.sh` 通过：模块边界、资源脚本测试、格式检查、Swift tests 和工程元数据。默认合成与命名 Kokoro 身份一致；缺失资源明确失败；Speech Action 请求 en-US。
- ✅ `scripts/build-ios.sh` 四个模拟器 scheme 全部通过。模拟器构建不代表 CoreAI 真机推理验收。
- ✅ `scripts/test-kokoro.sh` Release 五项测试通过，包含真实三图推理、非静音有限 PCM、序列/时间戳、finished、并发拒绝、取消与卸载。
- ✅ 当前 Mac 缓存加载 0.160 秒；固定英语句子生成 3.375 秒音频，两次首段 1.339 / 1.072 秒，总耗时 1.339 / 1.072 秒。音频 24 kHz mono，路径仍为 `/tmp/mobileharness-kokoro-0.wav` 和 `/tmp/mobileharness-kokoro-1.wav`。
- ❌ 本轮未执行 iPhone 安装/试听、持续热状态测量或完整真实 ASR→LLM→TTS 对话测试；英语提示不保证每次模型输出都符合输入范围。

该次英语单语默认切换的绑定和语言策略见 [ADR 0050](adr/0050-default-kokoro-synthesis.md)；随后已由 [ADR 0052](adr/0052-kokoro-coreml-bilingual.md) 的 Core ML 中英双语实现取代。以下一节记录后续验收；两阶段均不自动回退到 Apple TTS。

## Core ML 中英双语替换验收（2026-09-28）

当前实现取代前述 CoreAI 英语单语默认。FluidAudio 代码固定为 `20d4f0bd46d11d7f50a6eb4f7835cfdbd2b4ba14`，模型固定为 `006395f65025af251858b1ab0a7178a6a1e73f9f`。本地制品约 344 MiB（含两套语音图、词典及 g2pW）；不入 Git，App 不执行资源下载。

✅ `scripts/check.sh`、`scripts/build-ios.sh` 四个模拟器 scheme、MobileHarness 真机目标 Debug 无签名构建均通过。已确认 App 内存在 KokoroCoreML/ANE-zh 的实际图文件。真机编译/打包成功不代表已安装或试听。

✅ `scripts/test-kokoro.sh` Release 五项测试通过：中英脚本路由/混读顺序、长度限制与拒绝、英文词典和标点、真实合成的有限非静音 PCM/序列/时间戳/唯一 finished、并发拒绝、取消与卸载状态。

当前 Mac 缓存加载 0.811 秒；各样例均为 24 kHz 单声道 PCM：

| 固定测试文本 | 首段 PCM | 总合成 | 音频时长 |
| --- | --- | --- | --- |
| The quick brown fox jumps over the lazy dog. | 0.421 s | 0.422 s | 3.375 s |
| 你好，今天天气很好。 | 0.428 s | 0.428 s | 2.825 s |
| 你好，Hello world，再见。 | 0.152 s | 0.475 s | 3.750 s |
| 今天是2026年9月28日，价格是3.14元。 | 0.363 s | 0.363 s | 5.150 s |

样例保存在 `/tmp/mobileharness-kokoro-0.wav` 至 `-3.wav`。上述为单次运行数据，不是手机性能统计。混读在中文 zf_001 与英文 af_heart 间切换，尚非同一音色跨语言。

接入发现并修正：英文段尾的全角中文标点；上游 g2pW 封装的四输入接口与实际六输入/probs 制品不一致。当前 LocalMandarinFrontend 显式传递 char_ids、position_ids、phoneme_mask 等字段，并保留模型标签已经携带的声调数字，错误向上传播。

❌ 日语/法语/西语未接线。英文仍为词典与生词字母拼读；未接神经 G2P。没有完成中文读音准确率、完整真实 Agent 对话或 iPhone 安装/试听/持续热状态验收。

❌ 上游 FluidAudio #889 报告 iOS 27 上 BNNS/MPSGraph 进程崩溃。此版本包含输入缓冲尾页补齐，并选用 ANE + CPU noise/tail 路径；修复在目标 iPhone 上仍需长测确认。Mac 短测不能证明该风险已消除。
