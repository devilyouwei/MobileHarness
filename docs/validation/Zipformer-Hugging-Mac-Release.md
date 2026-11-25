# Zipformer 的 Hugging Mac Core ML 发布版回放

## 实施与验收口径

`experiments/decision/evaluate_zipformer_kws.py` 的 Core ML 入口改为直接运行
Hugging Mac 发布的 FP32 encoder、decoder 和 joiner。制品配置固定 Hub 提交、下载文件、
大小及 SHA-256。实验侧适配器复用 `Models/ZipformerKWS/` 中经过校验的缓存，通过
发布版 Python 流式宿主处理实验词表，记录每个命中的输入采样位置和分块计算时间。
`cpu` 与 `coreml-ep` 保留 Sherpa-ONNX 对照，历史结果保留各自原有来源和指标口径。

验收覆盖文件校验、缓存复用及冻结中英文音频回放。真实模型结果单独记录制品提交、
计算单元、样本数、P95 与计时口径。实验入口和缓存说明分别维护在
[Decision 实验](../../experiments/decision/README.md)与[模型目录](../../Models/README.md)。

## 实测结果

Apple M5、macOS 27.2.1、Python 3.13.13。使用已从 Hugging Face 下载并校验的
`46d5bc5be5acf590afdb8349d89bb2533f01ce48`，以 `CPU_ONLY`、chunk-8、blank=0
重放 24 条冻结音频，每条 4 种偏移，另执行 2 次预热。来源见
[Hugging Face 固定发布版](https://huggingface.co/hugging-mac/zipformer-kws-zh-en-3m-coreml/tree/46d5bc5be5acf590afdb8349d89bb2533f01ce48)。

96 次中 59 次正确。32 次明确打断中正确命中 23 次，64 次应保持中误打断 28 次。
首个命中标签与送入音频位置逐条等于同一夹具的[历史原生 Core ML CPU 回放](../../experiments/decision/results/zipformer-stop-native-coreml-2026-11-25.json)。
正确命中的延迟 P95 为 390 ms，0/32 次在 100 ms 内正确命中。触发原生 encoder
窗口的 PCM 包处理 P95 为 3.62 ms，共 1,705 个计时样本。包处理开销和音频命中延迟
采用不同的计时边界。见[本次原始结果](../../experiments/decision/results/zipformer-hugging-mac-coreml-verified-2026-11-25.json)。

下载校验、缓存复用、显式本地制品损坏拒绝和符号链接拒绝的 4 项离线回归通过。
本次真实模型验证使用 Mac，iPhone 真机与 App 集成未纳入回放。

实验离线总套件 39 项通过。Xcode 27.2 的 `./scripts/build-ios.sh` 完成 5 个模拟器
scheme 构建。`./scripts/check.sh` 在 Agent 资源归属与 State Value codec 的静态检查
阶段退出，未执行其后续 Swift 测试。
