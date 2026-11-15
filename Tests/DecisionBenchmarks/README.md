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
