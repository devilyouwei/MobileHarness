# Mac Decision 对照

离线评估本地模型的原始分类。独立 Swift 包只依赖 CoreAILM，Python 直接运行 D3 Core AI 图。两个入口都无需构建或启动 MobileHarness。这里保存冻结实验输入和制品配置。已出版的结果与方法见 [Mac 对照报告](../../docs/validation/Decision-Model-Mac-Comparison.md)。

| 制品 | 用例 | 输出协议 |
| --- | --- | --- |
| D3 Edge | 154 条，含三个冻结提示组和两个现行提示的冻结样本组 | Core AI 原生 Choice，A/B/C 对应打断、舍弃、入队 |
| Qwen2.5 1.54B INT8 | 原输出协议对照的 100 条 | 首 token 单词或数字打分，或严格生成一个完整单词或数字 |

这两套样例有各自的来源。横向比较只使用相同用例、预期和提示条件。Apple 系统模型与现行 Assistant renderer、采纳策略的核对继续使用 [IntegrationTests 的原生入口](../IntegrationTests/README.md#apple-system-decision-comparison)。它与这里的 D3 冻结用例有配对记录。历史报告保留超预算制品的测量证据。

## 文件与运行

- `models.json` 固定 Hugging Face revision、文本图路径、必需文件和 SHA-256。
- `fixtures.json` 保存合成输入和预期动作。现行提示组是迁移时的快照。
- `DecisionDecoder.swift` 是独立包的 Qwen 解码执行器。每条请求重置上下文，预热三次。
- `.local/` 存储权重、虚拟环境和本次输出，受 Git 忽略。

用 Apple Silicon、macOS 27、完整 Xcode 和 Python 3.13。从仓库根运行。

```bash
bench=Tests/DecisionBenchmarks
python3.13 -m venv "$bench/.local/venv"
"$bench/.local/venv/bin/python" -m pip install -r "$bench/requirements.txt"
python3 "$bench/benchmark.py" download d3-edge
python3 "$bench/benchmark.py" download qwen2.5-1.5b
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build --package-path "$bench" --configuration release
```

下载复用仓库的开发下载器，支持 `--endpoint` 选择 HTTPS Hugging Face 镜像。推理读取本地模型并核对图哈希。建议逐个运行以减少首次图编译的内存和临时空间竞争。

```bash
py="$bench/.local/venv/bin/python"
"$py" "$bench/benchmark.py" run d3-edge --output "$bench/.local/results/edge.json"
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

## Binary interrupt intent

三波二分类的输入、逐条结果和指标见[打断意图二分类报告](../../docs/validation/Decision-Binary-Interrupt-Mac-Comparison.md)。

`binary_interrupt_experiment.py prepare --output NEW_JSON` freezes 32 bilingual scenarios, each paired with busy/idle metadata, and two binary-choice prompts. Models receive only the utterance, common question and ordered false/true options; busy is used only by the offline action mapping: `busy && predicted_true ? interrupt : enqueue`. Raw intent and adopted-action scores are separate. There are 64 distinct utterances, not 128 independent examples per prompt.

Run the frozen matrix through `vela_comparison.py` (published CPU adapter) and the existing `d3PromptOptimizationExperiment` Swift entry (automatic mode), serially. `binary_interrupt_experiment.py summarize --input INPUT --report REPORT --output NEW_JSON` verifies input hash/row identity and computes confusion counts, precision/recall/F1, false-positive/negative rates, language/state/category breakdowns, P50/P95 and over-250ms counts. Invalid output remains an error, not an implicit false. Reports exclude load and warmup from latency; audio, queue waiting, playback cancellation and device actuation are not measured. No App binary protocol or behavior is installed by this experiment.

## Localized native noul / choice comparison

`localized_binary_experiment.py` adds five typed conditions without changing the App: native noul, an exactly equivalent choice control, localized short choices, defined boolean choices, and reversed defined choices. Chinese and English questions are separate. Each locale has 80 same-language cases (40 positive/40 negative), eight opposite-language cases, four mixed-language cases and six unlabelled ambiguity probes. The main set preserves the prior 32 scenarios and adds 48. Every condition has 196 requests; repeated conditions and bilingual pairs are not independent observations. Busy/idle is a downstream deterministic mapping, not repeated model traffic.

`prepare --upstream PATH --output docs/measurements/decision-localized-binary-MODEL-input-DATE.json` verifies the pinned upstream D3 format hash and emits separate D3/Vela fixtures. D3 typed questions render through the upstream formatter to the exact existing Swift wrapper; its official English protocol remains intact while instructions and user-defined option descriptions localize. Execute the D3 fixture via `d3PromptOptimizationExperiment`, then summarize with the upstream `to_answer` function. This bridge uses real CoreAI code logits, not a PyTorch upstream runtime invocation. Vela runs `vela --input INPUT --output OUTPUT` in the published Python environment and invokes the published adapter's `predict` with actual noul/choice question objects. It checks exact input-array parity between noul and the equivalent choice control for every case.

Use `summarize --upstream PATH --input INPUT --report REPORT --output NEW_JSON` for either model. It preserves raw typed responses, derives `pTrue`, applies the preregistered `pTrue > 0.5` threshold (ties false), and separates same-language, cross-language, mixed, regression/new and category metrics. Undefined diagnostic labels never enter accuracy, F1 or AUC. Invalid outputs remain failures. Metrics include confusion counts, balanced accuracy, precision/recall/F1, ROC AUC, Brier score, token range, warm-request P50/P95 and >250ms counts; option-order disagreements and noul/control probability differences are retained. Output files refuse initial overwrite. No thresholds or labels are fitted after observing results.

## History-depth binary comparison

`history_binary_experiment.py` creates a separate contextual benchmark; it never merges scores with the single-utterance experiments. State contains `conversation` (chronological user/assistant pairs) and `incoming_user_input`. The final pair retains the triggering user request and the assistant's already-emitted fragment, marked `is_current_turn: true`; it is not counted as completed history. No busy/playback/queue state is provided. Completed-history depth is 0/1/2/3/4. A depth of zero still includes the current exchange.

Each locale has 24 paired main scenarios and four opposite-language probes per depth; four native conditions (noul, equivalent choice, localized short choice, defined choice) yield 1120 requests/model. Eight main scenarios require specific earlier evidence; missing-evidence levels remain unspecified, excluded from accuracy. Per-depth summaries retain a fixed 16-case always-resolvable cohort, history-dependent coverage, and six positive/negative same-input counterfactual pairs. Earlier instructions are context, not commands for the classifier. History codeword cases are synthetic causal probes, not natural-traffic estimates.

`prepare --upstream PINNED_D3_FORMAT --output ...MODEL...json` freezes requests and source hashes. `preflight --upstream PATH --input D3_INPUT --output NEW_JSON` uses the published D3 environment's tokenizer with `return_dict=False`; records every actual token length, requires common inputs to fit 512 and reports a separate long-reply capacity probe. It neither truncates nor summarizes state. D3 executes through the existing Swift experiment. `vela --input VELA_INPUT --output NEW_JSON` reuses the pinned native adapter runner with the four conditions. Run models serially. `summarize --upstream PATH --input INPUT --report REPORT --output NEW_JSON` saves raw typed results, language/depth/type metrics, equivalent-control differences and counterfactual pair success. Run preflight with `USE_TORCH=0` in the D3 publication environment and Vela with its existing CPU environment.


App 二分类 Swift 对比入口为 IntegrationTests.decisionBinaryNativeComparison。设置 MH_BINARY_NATIVE_MODELS 为现有 .local/models，MH_BINARY_NATIVE_REPORT 为 docs/measurements 下独立结果文件。历史多分类 runner 使用测试专用 HistoricalDecisionBenchmarkSupport 的冻结协议/提示词，原数据和路径保留；当前 App 的二分类提示词不覆盖旧实验。

## Vela3.1 Fast frozen-matrix comparison

`vela31_comparison.py` replays the original four-class paired matrix, initial binary cases, localized noul/choice cases and current-turn/history-depth cases. `vela31-model.json` pins the decision graph, exact FP32 backbone and tokenizer/configuration to the published repository revision. Model bytes stay in the approved `.local/models/Vela31Fast`; the experiment imports the existing Hugging Mac SDK decision-only CoreAI engine through an explicit local resource view, without downloading unrelated adapters or runtime-irrelevant documentation. Source file hashes identify the SDK's working tree, not just its Git HEAD.

Use the existing Hugging Mac Python 3.12 environment with `USE_OS_COREAI=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 PYTHONDONTWRITEBYTECODE=1`. Run `vela31_comparison.py run --model vela31`, then the same command with `--model vela3`, serially. `--sdk` identifies the SDK checkout for source provenance; its installed Python package must correspond to that checkout. `--suite` optionally selects four/binary/localized/history; `--limit` is smoke-only and must use a distinct `--tag`. Formal reports are new `decision-vela31-comparison-*` files under docs/measurements; smoke reports belong in `.local` and are excluded from summaries. Never overwrite frozen prior reports.

Requests, questions, options, action mapping and the binary `> 0.5` rule remain frozen. Each question uses one inference; both engines include packing, native execution and decoding in elapsed time. Three warmups per condition and model load are reported separately. Errors remain errors. Ambiguity/missing-history cases are excluded from semantic metrics; original busy/idle repetitions are not independent samples. `summarize` computes the same binary metrics as the previous experiment and four-class confusion/macro-F1. `vela31_parity.py` compares the loader's complete answers/usage with three frozen original-checkpoint cases, independently of the routing dataset. The App and its runtime prompts are unchanged.

The separate `vela31_described_noul.py prepare` freezes one 3.1-only exploratory condition using the existing true/false descriptions as native noul criteria; `vela31_described_noul.py` runs 196 single-turn cases plus 56 current-turn (h0) cases and verifies token/tensor equivalence to described no/yes choice. It does not alter or retroactively tune the frozen five-condition comparison. `vela31_compare_results.py` joins fresh runs with historical D3/Vela reports by case ID, checks expected labels and exact D3 four-class request identity, and records paired changes plus native-noul/control agreement. Run all model inference serially before repository builds/tests so background compilation does not contaminate latency.

After both full runs, invoke `vela31_comparison.py summarize` once, then `vela31_compare_results.py`. The summarizer reads only the eight explicit raw-report paths; new outputs refuse overwrite. The paired JSON retains all locale/partition/type/depth groups; `alwaysResolvable` is the fixed cohort for history-depth comparisons. Recorded November 18 runs used coreai-core 1.0.0b2 and tokenizers 0.22.2; these differ from the older Vela environment documented above, so old Vela was rerun in the same environment.


## Laya Multilingual CoreAI comparison

`laya_comparison.py` uses `laya_artifact_adapter.py` for the pinned macOS wfp16-s512 artifact, the publisher’s unchanged `_laya_host.py` readout and the Laya 0.4.2 host package loaded from its wheel in the approved `.local/models/LayaMultilingual`. It does not install or upgrade shared-environment packages. All neural inference uses the 512-token CoreAI graph with explicit GPU preference; host PyTorch imports do not load PyTorch model weights. Version differences from the publisher's environment are recorded explicitly.

Run with the existing Hugging Mac Python environment, `USE_OS_COREAI=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 PYTHONDONTWRITEBYTECODE=1`, followed by `Tests/DecisionBenchmarks/laya_comparison.py`. `--suite` selects a frozen matrix; `--limit` writes smoke-only results to `.local` with a separate `--tag`. The original four/binary/localized/history inputs and the separate described-noul fixture are replayed without tuning. Before inference, all state, instruction and option spans are checked against the publisher's actual sequence builder; a truncated suite stops explicitly. The publisher's calibrated, four-decimal response probabilities are preserved, including the strict >0.5 boolean rule. Load and three warmups per condition are excluded from latency.

Laya encodes the question type in both its prompt and a learned type input. The frozen `choice_native_control` label refers to the old Vela/D3 control; it is not an assertion of equal Laya tensors or probabilities. Its `act` head is recorded only as adapter metadata, never used to override classification. Model process ownership bounds the standalone native session lifetime; there is no automatic fallback or App integration.

`laya_parity.py` checks all 201 published reference rows: exact host token/marker identity, equal selections and probability/act deltas <=1e-3 at T=1. Routing runs use the bundle’s published calibrated temperatures, recorded separately. `laya_compare_results.py` saves language/type/depth metrics and paired changes against frozen prior models. The initial 1024-token conversion did not load; its separate `laya-unloadable-model.json` and failure report are provenance only, not an alternate successful backend. The failed graph was removed locally to recover space.

The successful GPU specialization uses `with_debug(enabled=True)` to reuse the verified compilation cache after disk exhaustion prevented a second specialization. Reports record this setting; do not compare its latency to prior CPU runs as a hardware-neutral model ranking. Reproduce summaries with Python 3.12 (the shared digest helper uses `hashlib.file_digest`), not the system Python 3.9.


## Concise current-conversation intent experiment

`concise_intent_experiment.py` freezes the user-proposed natural-language layout: current user/assistant exchange, latest user message, and a short intent question. Chinese/English instructions and the four bare categories localize; category order is interrupt / unfinished / meaningless / wait. For scoring only, wait maps to the prior enqueue label. Binary conditions are native noul and bare No/Yes choice. It uses the same 54 four-class, 196 single-message and 56 h0 contextual cases, preserving labels; no earlier history, busy flag or queue metadata enters the new state. Existing held fragments in historical four-class cases remain joined exactly as in the source fixture, only in experiments.

Run Python3.12 `concise_intent_experiment.py prepare`, `preflight-d3` (with USE_TORCH=0), then `run --model laya` and `run --model vela31` serially with the existing CoreAI environment variables. D3 uses the unchanged `d3PromptOptimizationExperiment` Swift entry for each of the three `decision-concise-intent-d3-*-input-2026-11-18.json` fixtures: set D3_PROMPT_OPT_INPUT and D3_PROMPT_OPT_REPORT to the matching absolute input/result paths. Its noul requests are lowered with the pinned official formatter into the exact native choice-code readout, as in prior experiments. Do not replace its native chat template. Three warmups per condition are separate from 558 formal requests/model.

`concise_intent_experiment.py summarize` joins all three completed models, retains per-case probabilities/errors, and computes language/partition/type metrics. Outputs use a new `decision-concise-intent-*` prefix and refuse overwrite. Laya GPU debug-enabled, Vela3.1 CPU and D3 automatic execution paths differ; timing is not a same-device-placement model ranking. Old scores are regression references, not an ablation separating structure, brevity, language and category-order changes. No App prompt or result-adoption policy is changed.

## Defined concise intent experiment

`defined_intent_experiment.py` reuses the concise runner and Laya adapter. `prepare` copies the frozen concise shared fixtures and changes only question instructions: separate Chinese/English immediate-interruption boundaries and one short definition per four-class category. Candidate strings/order, scenario labels, context and threshold remain identical. Variant names retain `concise_noul`/`concise_choice` to allow exact pairing; the `decision-defined-intent` file prefix identifies this condition. `run` executes only Laya; `summarize` pairs prior and new results and scores language/partition/type separately. Run the three commands serially with the Python3.12/CoreAI environment above. It does not overwrite historical fixtures or modify App prompts.

## Swift decision adapter parity

`decision_adapter_parity.py` freezes 30 four/single/current requests per added provider from the completed concise Python run, plus separate Laya token-span references. `DecisionAdapterNativeTests.swift` uses explicit DECISION_ADAPTER_INPUT/REPORT and optional DECISION_ADAPTER_MODEL (vela31/laya) to execute native Swift providers without downloads; LAYA_TOKEN_INPUT enables token-span parity. Mac Laya reads the macos source bundle directly; the App catalog downloads the portable iOS bundle. Choice/noul probabilities and labels must match within 0.001; these are adapter checks, not new semantic scores or device validation. Ordinary tests do not load large weights.
