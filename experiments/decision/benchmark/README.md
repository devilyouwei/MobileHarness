# Decision benchmark tools

本目录是纯 Python 的固定矩阵、特定模型与历史结果配对工具；通用入口见 [Decision](../README.md)。不再包含独立 Swift 包或执行器。

| 工具 | 职责 |
| --- | --- |
| `benchmark.py` | D3与Qwen基准；Qwen使用`utils/coreai_decoder.py` 逐token解码 |
| `binary_interrupt_experiment.py`、`localized_binary_experiment.py`、`history_binary_experiment.py` | 冻结二分类/语言/历史窗口输入与指标 |
| `continuation_prompt_experiment.py`、`summarize_continuation.py` | 历史续听提示准备与结果汇总 |
| `d3_cpu_comparison.py`、`vela_comparison.py`、`vela31_comparison.py`、`laya_comparison.py` | 固定制品原生Python对照 |
| `concise_intent_experiment.py`、`defined_intent_experiment.py`、`vela31_described_noul.py` | 特定提示变体 |
| `multi_noul_experiment.py` | 多问题输入准备和历史结果汇总；新推理由 `../evaluate_decision.py` 执行 |
| `*_compare_results.py` | 冻结结果配对，旧测量不冒充同期速度对照 |
| `laya_artifact_adapter.py` | 已发布Laya制品的Python接口 |
| `*-model.json`、`models.json` | 模型版本、路径和文件校验和 |

输入归 `../datasets`，原始结果归 `../results`，权重归仓库根 Models。制品附带的历史 Swift 验证文件只是清单中的上游文件，不执行或编译。Qwen/Gemma 的 Core AI 生成需要兼容的本地图与 tokenizer；符号状态维度按显式上下文容量分配，也可通过配置覆盖。

安装本目录 requirements；Vela3.1另需 Hugging Mac Python SDK，Laya使用已校验的制品wheel。运行 `python3 experiments/decision/benchmark/benchmark.py --help` 查看入口。历史准备工具保留固定日期/来源格式，已有文件不得覆盖；新研究优先使用通用 Decision 入口与新输出文件。

运行器只读取已准备好的 Models 制品，不导入仓库下载库。缺失制品时，按对应模型清单的来源 URL 和固定版本先下载到 Models；避免在实验目录另存权重。
