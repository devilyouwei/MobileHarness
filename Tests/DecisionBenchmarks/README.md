# Mac Decision 对照

离线评估本地模型的原始分类。独立 Swift 包只依赖 CoreAILM，Python 直接运行 D3 Core AI 图。两个入口都无需构建或启动 MobileHarness。这里保存冻结实验输入和制品配置。已出版的结果与方法见 [Mac 对照报告](../../docs/validation/Decision-Model-Mac-Comparison.md)。

| 制品 | 用例 | 输出协议 |
| --- | --- | --- |
| D3 Edge、D3 Lite | 154 条，含三个冻结提示组和两个现行提示的冻结样本组 | Core AI 原生 Choice，A/B/C 对应打断、舍弃、入队 |
| Qwen2.5 1.54B INT8 | 原输出协议对照的 100 条 | 首 token 单词或数字打分，或严格生成一个完整单词或数字 |

这两套样例有各自的来源。横向比较只使用相同用例、预期和提示条件。Apple 系统模型与现行 Assistant renderer、采纳策略的核对继续使用 [IntegrationTests 的原生入口](../IntegrationTests/README.md#apple-system-decision-comparison)。它与这里的 D3 冻结用例有配对记录。历史报告保留超预算制品的测量证据。

## 文件与运行

- `models.json` 固定 Hugging Face revision、文本图路径、必需文件和 SHA-256。
- `fixtures.json` 保存合成输入和预期动作。现行提示组是迁移时的快照。
- `benchmark.py` 负责下载、编码、执行、计分和 JSON 输出。D3 Edge 与 Lite 文本路径共用三输入接口。旧版 Lite 本机制品可运行 `benchmark.py download d3-lite --force` 更新，归档报告保留当时的制品版本。
- `DecisionDecoder.swift` 是独立包的 Qwen 解码执行器。每条请求重置上下文，预热三次。
- `.local/` 存储权重、虚拟环境和本次输出，受 Git 忽略。

用 Apple Silicon、macOS 27、完整 Xcode 和 Python 3.13。从仓库根运行。

```bash
bench=Tests/DecisionBenchmarks
python3.13 -m venv "$bench/.local/venv"
"$bench/.local/venv/bin/python" -m pip install -r "$bench/requirements.txt"
python3 "$bench/benchmark.py" download d3-edge
python3 "$bench/benchmark.py" download d3-lite
python3 "$bench/benchmark.py" download qwen2.5-1.5b
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build --package-path "$bench" --configuration release
```

下载复用仓库的开发下载器，支持 `--endpoint` 选择 HTTPS Hugging Face 镜像。推理读取本地模型并核对图哈希。建议逐个运行以减少首次图编译的内存和临时空间竞争。

```bash
py="$bench/.local/venv/bin/python"
"$py" "$bench/benchmark.py" run d3-edge --output "$bench/.local/results/edge.json"
"$py" "$bench/benchmark.py" run d3-lite --output "$bench/.local/results/lite.json"
"$py" "$bench/benchmark.py" run qwen2.5-1.5b --mode score-words --output "$bench/.local/results/qwen.json"
```

Qwen 另支持 `score-digits`、`words` 和 `digits`。各条件可用 `--limit N` 做烟雾测试，输出须使用新路径。计分保留误打断、漏打断、误丢弃、无效输出、混淆矩阵和 500 ms 预算。推理错误使运行明确失败。时延包括文本编码、推理及读出，排除加载和预热。当前输出是 Mac 合成文本实验，应用采纳规则、ASR、执行和真机延迟另行验证。

## 继续聆听四分类

最新 App 四分类由 [IntegrationTests 的独立入口](../IntegrationTests/README.md#d3-edge-continuation-classification-experiment) 实测，继续复用这里 `.local/models/D3Edge` 的制品。原 `fixtures.json`、`benchmark.py` 与其他模型入口保持不变。`summarize_continuation.py REPORT --artifact ARTIFACT_JSON --output FRESH_JSON` 只汇总四分类报告，不加载模型；artifact JSON 包含本次主机、制品 manifest 与文件哈希。汇总按语言、场景类别、原始/采纳结果区分，并单列512 token、250ms和容量保护。冻结样例与结果位于 `docs/measurements`，分析追加到原 [Mac 对照报告](../../docs/validation/Decision-Model-Mac-Comparison.md#d3-edge-继续聆听四分类实验2026-11-16)。

```bash
python3 Tests/DecisionBenchmarks/summarize_continuation.py \
  docs/measurements/decision-continue-listening-d3-edge-2026-11-16.json \
  --artifact docs/measurements/decision-continue-listening-artifact-2026-11-16.json \
  --readout docs/measurements/decision-continue-listening-readout-2026-11-16.json \
  --output /tmp/decision-continuation-summary-new.json
```

## 实验环境提示词优化

`continuation_prompt_experiment.py`只生成实验请求和评分，不改App资源，也不加载其他模型。`prepare`生成首轮七组开发集请求，并在任何评分前冻结48条留出；`refine`生成仅开发集的四组话语状态标签对照；已有留出必须完全一致。`summarize --report REPORT --output NEW_JSON`计算四类macro-F1、继续聆听精确率/召回率、误打断/误舍弃、token及耗时；容量/采纳/键盘探测排除在语义评分外。`holdout --variant NAME`只生成基线和已选方案的留出请求。生成的已发布文件拒绝覆盖。

原生推理由[IntegrationTests入口](../IntegrationTests/README.md#experimental-d3-prompt-optimization)执行。运行后用以下方式独立复算结果：

```bash
python3 Tests/DecisionBenchmarks/continuation_prompt_experiment.py summarize \
  --report docs/measurements/decision-prompt-optimization-results-2026-11-16.json \
  --output /tmp/decision-prompt-optimization-summary-new.json
```

方案取开发集四类macro-F1最高者，并列时取更短者；报告错误类型而不只看4的选择次数。留出复核后不再针对其输出调模板。语义选项直接符合D3的`key: description`呈现，继续聆听前置组独立记录选项映射。研究来源、结果和限制见[原Mac报告](../../docs/validation/Decision-Model-Mac-Comparison.md#d3-edge-提示词结构优化实验2026-11-16仅实验环境)。

## Vela3 Fast paired comparison

`vela-model.json` pins the remote revision and every copied file hash. The approved `.local/models/Vela3Fast` directory sits beside D3Edge. `vela_comparison.py` loads the verified published adapter only for offline experiments, using CPU and Vela-native markers. State, question, A/B/C/D candidate meanings and action order match the D3 request matrix; no App configuration changes. Use Python 3.12 with coreai-core 1.0.0b3, numpy 2.3.5 and tokenizers 0.23.3.

Run with `USE_OS_COREAI=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 /path/to/python Tests/DecisionBenchmarks/vela_comparison.py --input docs/measurements/decision-vela-d3-input-2026-11-17.json --output /tmp/vela-new-results.json`. Output must not exist. The runner verifies artifact/source hashes, warms each condition three times, rotates conditions, and records raw classifications, probabilities, tokens, errors and elapsed time. It rechecks sources and input on completion. The same matrix runs through the existing D3PromptOptimizationTests entry. Keep diagnostic cases separate from the 48-case holdout. Vela CPU and D3 automatic-mode timing describe different execution paths, not matched accelerators.

`d3_cpu_comparison.py` provides an isolated CPU diagnostic with the same input/output CLI. It preserves the D3 chat template, 512-token left padding, four position axes and native candidate readout. Use an environment also containing transformers, with `USE_TORCH=0`. It stops on a failed warmup. On the recorded host the D3 CPU graph returned no finite logits; this is a runtime failure, not a classification score.
