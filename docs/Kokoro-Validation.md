# Kokoro CoreAI 验证

日期：2026-09-24。指定模型：[mlboydaisuke/Kokoro-82M-CoreAI](https://huggingface.co/mlboydaisuke/Kokoro-82M-CoreAI)，固定 revision `b869e4ceed2e99dba3491f613403ac2240505250`。

## 范围

独立 `ModelKitKokoro` capability 和 `KokoroValidation` 真机入口。默认中文对话保持 Apple TTS。模型图、US 词典、af_heart 和 DSP 数据合计 346,431,925 bytes；只下载推理需要的音色，均带 SHA-256，不入 Git。Swift 宿主代码来源 coreai-kit `7d5403e6e5d75a6f204814e56bbe342034744746`，复用现有 CoreAI 后端。

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
