# Decision experiments

[evaluate_decision.py](evaluate_decision.py) 直接通过 Python 调用模型，支持冻结 choice 请求、布尔判断、多问题和文本分类；不执行 App 的接纳、排队、回退或超时策略。

```bash
python3 experiments/decision/evaluate_decision.py --model d3-edge \
  --input experiments/decision/datasets/decision-prompt-optimization-input-2026-11-16.json \
  --output experiments/decision/results/prompt-d3-new.json
python3 experiments/decision/evaluate_decision.py --config experiments/decision/apple-model.json \
  --input experiments/decision/datasets/gemma-decision-cases.json \
  --output experiments/decision/results/apple-new.json
```

- `--model` 选择 d3-edge、vela3-fast、vela31-fast、laya，本地制品从 `--models-root`（默认 Models）读取；[decision_models.py](decision_models.py) 拥有原生 Python 读出，检查固定制品哈希。
- `--config` 使用 Apple 系统模型、Core AI 生成模型或云端文本接口。Gemma 配置见 [gemma-model.json](../assistant/gemma-model.json)。文本输出严格解析，解释文字不算有效标签。
- `--limit` 用于小样本诊断；`--warmup` 的调用不计入正式样本；`--timeout` 限制单 case。多问题按两种题序运行，保留每题概率，不混同完整 App 请求耗时。
- 冻结 `request/native` 原样作为模型输入。原始业务/语言场景使用 Python 实验提示组织输入，这种新格式与旧 Swift 渲染分开比较。
- [datasets](datasets/README.md) 拥有输入；[results](results/README.md) 拥有历史及新原始输出；[benchmark](benchmark/README.md) 拥有固定矩阵准备、配对汇总和特定制品对照。
- [historical-prompts.json](historical-prompts.json) 是原历史实验提示词的冻结副本，不从 App 资源动态读取。当前 App 提示构造契约由 Tests 验证。

## quiet 退出判定

[evaluate_quiet_exit.py](evaluate_quiet_exit.py) 评估 Assistant 在 quiet 模式下仅凭最新一句话判断是否退出。用例 [quiet-exit-cases-2026-11-23.json](datasets/quiet-exit-cases-2026-11-23.json)，冻结提示词 [quiet-exit-prompts.json](quiet-exit-prompts.json)；生成式后端（Apple、云端）使用与 App 相同的 system/user 结构并答 exit/stay，原生 Decision 模型使用同一指令的布尔问句。云端配置 [quiet-cloud-model.json](quiet-cloud-model.json) 的密钥只经环境变量读取（默认 `EXPERIMENT_API_KEY`），endpoint 按实际服务修改或使用不入库的本地副本。

```bash
python3 experiments/decision/evaluate_quiet_exit.py --model laya --output experiments/decision/results/quiet-exit-laya-DATE.json
python3 experiments/decision/evaluate_quiet_exit.py --config experiments/decision/apple-model.json --output experiments/decision/results/quiet-exit-apple-system-DATE.json
python3 experiments/decision/evaluate_quiet_exit.py --config experiments/decision/quiet-cloud-model.json --output experiments/decision/results/quiet-exit-qwen3-8-flash-DATE.json
```

报告 JSON 同时含总体 `metrics` 与中英分开的 `metricsByLanguage`。`--prompts quiet-wake-short-prompts.json` 选择最短问句（`template` 单条 user 消息）。`--prompts quiet-wake-prompts.json` 选择简化的是非问句变体（文件中 `answer` 为 `boolean`，生成式后端答 true/false）。

新版提示词快照 [quiet-exit-current-prompts-2026-11-25.json](quiet-exit-current-prompts-2026-11-25.json) 使用 version 2。它支持无条件和语义约定两条分支，生成式后端只接受完整的单词 verdict，原生后端读取同一证据的布尔问句。无条件请求的正文为一句话，有约定时正文只含 `latestUtterance` 和 `wakeCondition`。`literal:` 由 App 直接匹配，实验模型输入只覆盖语义约定。

```bash
python3 experiments/decision/evaluate_quiet_exit.py --model d3-edge \
  --input experiments/decision/datasets/quiet-exit-current-cases-2026-11-25.json \
  --prompts experiments/decision/quiet-exit-current-prompts-2026-11-25.json \
  --limit 64 --warmup 2 --timeout 30 \
  --output experiments/decision/results/quiet-exit-current-d3-edge-rerun.json
```

方法与结果见 [新版对照](../../docs/validation/Quiet-Exit-Decision-2026-11-25.md) 和 [历史对照](../../docs/validation/Quiet-Exit-Evaluation.md)。离线回归见 [test_evaluate_quiet_exit.py](test_evaluate_quiet_exit.py)。

## Zipformer 打断口令回放

[evaluate_zipformer_kws.py](evaluate_zipformer_kws.py) 用冻结的 16 kHz PCM 和实验词表回放
打断口令。`--provider coreml` 直接运行 Hugging Mac 发布的三个 FP32 Core ML ML Program
和随制品发布的流式宿主。回放音频需从仓库外提供。首次运行按[固定提交与哈希清单](zipformer-coreml-model.json)下载，
后续复用 [Models/ZipformerKWS](../../Models/README.md) 的已校验制品。运行需要
`numpy`、`coremltools==9.0` 和 `kaldi-native-fbank==1.23.3`。

```bash
python3 experiments/decision/evaluate_zipformer_kws.py \
  --input /path/to/frozen-zipformer-audio.zip \
  --provider coreml --chunk 8 --blanks 0 \
  --output experiments/decision/results/zipformer-hugging-mac-coreml-rerun.json
```

原生 Core ML 默认用 `CPU_ONLY`，可用 `--compute-unit ALL` 对照。`--models` 可指向
同一已发布版本的完整本地制品目录，仍会逐文件校验。命中延迟按音频时间轴统计，
解码 P95 统计触发原生 encoder 窗口的 PCM 包处理时间。见
[发布版回放](../../docs/validation/Zipformer-Hugging-Mac-Release.md)。

历史对照继续使用 `--provider cpu` 或 `--provider coreml-ep`，配合
`--models /path/to/sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20` 及
`--chunk 8` 或 `--chunk 16`。两者使用 sherpa-onnx 2.0.3，历史口径和结果见
[Core ML 对照](../../docs/validation/Zipformer-Apple-CoreML-Comparison-2026-11-25.md)。

[tune_zipformer_interrupt.py](tune_zipformer_interrupt.py) 采集分块、识别阈值和起声门限的开发或留出结果。[score_zipformer_interrupt_tail.py](score_zipformer_interrupt_tail.py) 用已收采样重算尾部静音门限和句尾口令延迟。[旁路候选](zipformer-interrupt-observer-2026-11-25.json) 固定 ONNX 权重、词表和配置，筛选与复核见[配置评估](../../docs/validation/Zipformer-Interrupt-Config-2026-11-25.md)。

方法和结论写入 [docs/validation](../../docs/validation/README.md)，Python 验证与真实模型测量分别报告。
