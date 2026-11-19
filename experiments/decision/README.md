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

方法和结论写入 [docs/validation](../../docs/validation/README.md)，Python 验证与真实模型测量分别报告。
