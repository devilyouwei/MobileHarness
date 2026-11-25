# 中英 Zipformer 的 Core ML 与 ONNX 对照

## 方法

先用相同的双语 ONNX 图与 sherpa-onnx 解码器比较 CPU 执行和 ONNX Runtime 的 Core ML Execution Provider。固定先前冻结的音频字节、词表、32 ms 输入包、四种分块偏移和每配置两次预热，重跑 chunk-8、chunk-16 与尾随 blank 0、1 的四组配置。逐条核对首次命中标签与音频输入位置，另外检查 encoder、decoder、joiner 的数值差和实际执行提供者。记录 Core ML 转换覆盖及 CPU 回退证据。

评估入口放在现有 `experiments/decision/`，回放夹具与逐条结果分别归 `datasets/` 和 `results/`。Core ML Execution Provider 对照经过 ONNX Runtime 分区，独立 Core ML 导出单列结果。参照 [ONNX 基线](Zipformer-Apple-ONNX-Baseline-2026-11-25.md) 的评分与时延口径。

Mac 为 Apple M5、macOS 27.2.1 arm64，Python 3.13.13。所有回放均使用相同的 24 条冻结音频和词表（音频 ZIP 未随仓库分发），每个配置 96 条正式回放。正确率中应打断以首个命中标签为准，应保持以全程无命中为准。命中延迟以估计口令尾部至检测时已送入的 PCM 位置计算，只统计正确命中。漏检仍计入 100 ms 达成率的分母。

## 同权重 ONNX 执行对照

sherpa-onnx 2.0.3 使用原 ONNX 包的 INT8 encoder 与 joiner、FP32 decoder。CPU 和 Core ML EP 使用同一解码器，共 768 条计分回放。两组的权重与夹具哈希一致，四种设置在每条回放上首个命中标签一致。见 [CPU 原始结果](../../experiments/decision/results/zipformer-stop-cpu-2026-11-25.json)与 [Core ML EP 原始结果](../../experiments/decision/results/zipformer-stop-coreml-2026-11-25.json)。

| 分块 / blank | 正确 / 96 | 误打断 / 64 | 解码 p95，CPU → Core ML EP（ms） | 命中 p95，CPU → Core ML EP（ms） |
| --- | ---: | ---: | ---: | ---: |
| 8 / 0 | 59 | 28 | 2.05 → 7.79 | 390 → 400 |
| 8 / 1 | 59 | 28 | 2.05 → 8.21 | 430 → 430 |
| 16 / 0 | 63 | 28 | 2.94 → 9.68 | 510 → 510 |
| 16 / 1 | 63 | 28 | 3.01 → 10.52 | 550 → 550 |

在 8 / 0 配置中，有 1 次正确命中的取样位置延后 160 ms。其他配置的正确命中位置一致。所有配置均为 0/32 次在 100 ms 内正确命中。

独立用 ONNX Runtime Python 1.24.4 对该 INT8 图组合做提供者诊断。NeuralNetwork 与 MLProgram 两种分区格式都生成了 Core ML 缓存。三个子图的 profile 同时出现 Core ML 和 CPU kernel，显式关闭 CPU fallback 后均拒绝初始化。8 个确定性张量输入的 encoder 主输出最大绝对差分别约 0.088 和 0.086。此诊断独立于 sherpa 内置运行时，用于证明分区与回退。见 [覆盖和数值原始记录](../../experiments/decision/results/zipformer-coreml-coverage-2026-11-25.json)与 [ONNX Runtime 执行提供者文档](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)。

## 独立 Core ML 导出与同后处理对照

从双语 Icefall 权重的 Safetensors 固定复刻 `0e33d140e0543a03bddf77dbbaad84ef6f4b3ef1` 导出 `chunk-8`、batch 1 的 encoder、decoder 与 joiner 为三个 FP32 ML Program。Python 通过 `coremltools.models.MLModel.predict` 直接调用，无 ONNX Runtime 分区参与 Core ML 前向。导出保留 encoder 循环缓存的输入输出，针对固定可整除分块略去零长度补齐，并以标量值绕过 TorchScript 转换器的 NumPy 单元素转换错误。和发布包同分块的 FP32 ONNX 比较时，CPU_ONLY 与 ALL 两组中 encoder 所有输出最大绝对差不超过 `2.77e-5`，decoder 不超过 `1.91e-6`，joiner 不超过 `5.73e-6`。来源与各制品哈希见[覆盖和数值原始记录](../../experiments/decision/results/zipformer-coreml-coverage-2026-11-25.json)及[固定模型来源](https://huggingface.co/MigoXV/icefall-kws-zipformer-zh-en-3M-2025-12-20/tree/0e33d140e0543a03bddf77dbbaad84ef6f4b3ef1)。

用 kaldi-native-fbank 1.23.3 和同一份 Python 参考 beam search 复用冻结音频，比较三个经相同后处理的后端。每个后端跑 `chunk-8 / blank=0` 共 96 条，记录首个命中即停止。decoder 和 joiner 均以 batch 1 逐路执行；计时包含子图与 Python beam search，跟上表 sherpa 内置 C++ 路径的调用边界不同。见 [Native Core ML 原始结果](../../experiments/decision/results/zipformer-stop-native-coreml-2026-11-25.json)与[固定参考解码器](https://huggingface.co/openEuler/sherpa-kws/blob/b73da3087e40072f6251351acd5f54a8c563bd11/assets/reference_impl/kws_decode.py)。

| 后端 | 正确 / 96 | 明确口令命中 / 32 | 误打断 / 64 | 分块计算 p95（ms） | 命中 p95（ms） |
| --- | ---: | ---: | ---: | ---: | ---: |
| FP32 ONNX CPU | 59 | 23 | 28 | 2.45 | 390 |
| 独立 Core ML CPU_ONLY | 59 | 23 | 28 | 2.53 | 390 |
| 独立 Core ML ALL | 59 | 23 | 28 | 6.52 | 390 |

独立 Core ML 两种计算设置均与 FP32 ONNX 的 96 条首个命中标签及输入采样位置逐条一致，三组都为 0/32 次在 100 ms 内正确命中。ALL 允许系统选择设备，不独立证明实际执行单元。FP32 Core ML 包约 12 MB，三个 `.mlpackage`、生成脚本和参考重放入口保存在本机 `/private/tmp/mh-kws-onnx.xhGjWE/zipformer-zh-en-chunk8-coreml-fp32-2026-11-25.zip`。包 SHA-256 为 `c9755cf5ab02f34aa0f1e4145a0d247ffc5946224d20c8c1eb98a54d6cf48dc2`，权重未入库。

## 结论

独立 Core ML 路径已经达到这批样本的首命中一致性，命中 p95 仍为 390 ms。保留 CPU ONNX 作为当前性能参照。降低音频等待以及处理否定和转述仍是打断方案的下一项验证，数据暂不足以支持即时取消。Python 离线回归 35 项通过，真实模型完成 1,056 条计分回放。真机、实际停播和原生 App 集成未测。
