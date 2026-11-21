# Assistant experiments

| 文件 | 职责 |
| --- | --- |
| [evaluate_qwen.py](evaluate_qwen.py) | 按多轮 case 直接调用模型，提供合成动作反馈；支持配置中的云端、Apple 或 Core AI 文本后端 |
| [workflow_scoring.py](workflow_scoring.py) | XML动作解析、顺序/参数/Skill状态与表情等评分 |
| [assistant-evaluation.json](assistant-evaluation.json) | 实验提示词与动作目录；不使用 App 的注册/执行链路 |
| [evaluate_prompts.py](evaluate_prompts.py) | 显式 system prompt 矩阵的原始回答与计时；语义质量需单独评审 |
| [compare_qwen_protocols.py](compare_qwen_protocols.py) | 云端 XML/native/mixed 协议对照，使用合成函数反馈 |
| [evaluate_wait.py](evaluate_wait.py) | wait 作用域/延时提示词评估：单轮请求，严格解析后在主轨道/Channel 时间线模拟上断言先后、并行与间隔 |
| [wait-prompt.json](wait-prompt.json) | wait 评估使用的生产英文提示词冻结副本（含来源哈希）与手写目录 |
| [gemma-model.json](gemma-model.json) | 本地 Gemma Core AI 图、tokenizer 和 PLE 静态表配置 |
| [datasets](datasets/README.md) / [results](results/README.md) | 任务输入与原始输出 |

```bash
python3 experiments/assistant/evaluate_wait.py --model qwen3.8-flash --repeats 3 \
  --output experiments/assistant/results/wait-prompt-qwen3.8-flash-<date>.json
python3 experiments/assistant/evaluate_qwen.py --config /path/to/model-config.json \
  --cases plain-chat --output experiments/assistant/results/chat-new.json
```

case 标签只供评分，不作为模型上下文。动作仅改变 Python 合成状态，不发送设备指令。请求轮数和 case 时限显式限制。新提示/合成反馈路径不是旧 App 运行器的逐字复刻，不将两者耗时或成功率混算。少量真实 Assistant/Gateway 通信验证由 [Tests/Agents/Assistant](../../Tests/Agents/assistant/README.md) 拥有。

本任务运行器的离线回归由 test_evaluate_qwen.py、test_compare_qwen_protocols.py、test_evaluate_wait.py 拥有，使用 `python3 -m unittest discover -s experiments/assistant -p "test_*.py"` 独立执行，不依赖工程 Tests。
