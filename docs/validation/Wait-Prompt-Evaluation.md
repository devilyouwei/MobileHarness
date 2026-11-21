# wait 提示词真实模型评估

日期：2026-11-21。范围：[Basic Interaction](../../MobileHarness/Resources/Skills/BasicInteraction/Instructions.md) 中 `wait` 教学能否让模型生成语义正确的 function token 组合（成对 `<wait>…</wait>` 作用域、自闭 `<wait time="秒"/>` 延时）。需求见 [Action-Multi-Channel-Wait](../requirements/technical/Action-Multi-Channel-Wait.md)，工程验证见 [同名验证记录](Action-Multi-Channel-Wait.md)。

## 方法

- 运行器 [evaluate_wait.py](../../experiments/assistant/evaluate_wait.py)，纯 Python 直连云端 chat/completions，单轮、`temperature=0`，每 case 重复 3 次。
- 提示词为 [wait-prompt.json](../../experiments/assistant/wait-prompt.json)：生产英文 OutputProtocol 与 Basic Interaction Instructions 的冻结副本（来源哈希在文件内）、手写 Action 目录和一行状态。不经过 App 注册、Gateway 或调度链路。
- 数据集 [wait-prompt-cases.json](../../experiments/assistant/datasets/wait-prompt-cases.json)：16 个 case，类别为无需 wait、串行、并行、嵌套、延时、混合、上限。标签不进入请求；中英文各有覆盖。
- 评分不比对字符串：先用严格语法解析（未知 Action、Markdown 围栏、非法 time、嵌套深度、32 个 wait、60 秒/120 秒预算），再用与需求算法一致的主轨道/Channel 时间线模拟（作用域开始等待父组、结束等待组内全部工作，延时只推进主轨道），断言 before / overlap / startGap / endGap 以及“不应有 wait / 不应说话”。因此等价写法均可通过。
- 模拟时长为假设值（express 2s、speech 3s、setExpression 0.1s），仅用于使顺序与间隔可判定；它不是真实演出时长。
- 离线回归：[test_evaluate_wait.py](../../experiments/assistant/test_evaluate_wait.py)，`python3 -m unittest discover -s experiments -p "test_*.py"` 25 项通过，不代替模型评估。

## 结果

原始输出：[qwen3.8-max](../../experiments/assistant/results/wait-prompt-qwen3.8-max-2026-11-21.json)、[qwen3.8-flash](../../experiments/assistant/results/wait-prompt-qwen3.8-flash-2026-11-21.json)、[gpt-4.1](../../experiments/assistant/results/wait-prompt-gpt-4.1-2026-11-21.json)。每模型 48 次请求，三个模型并行运行。

| 模型 | 全部通过 | 去除 limit-request | 请求错误 | p50 | p95 |
| --- | --- | --- | --- | --- | --- |
| qwen3.8-max | 43/48 | 43/45 | 2（均为 120 秒超时） | 9.3 s | 54.5 s |
| qwen3.8-flash | 45/48 | 45/45 | 1（120 秒超时） | 4.7 s | 39.4 s |
| gpt-4.1 | 44/48 | 44/45 | 0 | 2.0 s | 3.4 s |

按类别（通过/次数，三模型一致处合并）：无需 wait 9/9（gpt-4.1 为 8/9）、串行 9/9、并行 3/3、嵌套 6/6、延时 max 14/15 其余 15/15、混合 max 2/3 其余 3/3、上限三模型均 0/3。

## 发现

1. 核心语义均被正确理解：串行、并行、嵌套三步、“每个表情配语音”分组、整秒与 0.5 秒延时、“语音结束后再等 2 秒”（`<wait>…</wait><wait time="2"/>`）以及“说一，停两秒，说二”的陷阱（模型使用了作用域而非把延时直接放在语音之间）均通过；两个 qwen 与 gpt-4.1 在这些类别上无语义失败。
2. 上限 case（“等待五分钟”）全部失败：gpt-4.1 三次均输出 `time="300"`（超过 60 秒），qwen 两个模型把 300 秒拆成五个 `time="60"`，绕过单次上限但超过 120 秒/响应预算。教学中的上限文字没有让模型拒绝或缩短，需要决定是否在 Instructions 中加入“超限时缩短并说明”的指引，或依赖生成器的拒绝反馈。
3. gpt-4.1 的 `voice-exit#r3` 输出 `Goodbye.<stopListening/>`，违反“语音退出仅输出 stopListening”的既有规则；与 wait 无关。
4. qwen3.8-max 的 3 个未通过 case 中 2 个是超时（`two-delays#r1`、`speech-wait-then-expression-silent-delay#r2`），未得到可评分的回答，不能据此判断语义；flash 的超时出现在 limit-request。

## 补充：放宽语音退出后的复测

按需求决定，Listening 段改为“`<stopListening/>` 可附一句简短告别”，示例给出 `Goodbye.<stopListening/>`，`voice-exit` 评分不再禁止说话。修订后的冻结提示词为 [wait-prompt-farewell.json](../../experiments/assistant/wait-prompt-farewell.json)，只复测该 case（3 模型 × 3 次，原始输出 `wait-prompt-voice-exit-*-2026-11-21.json`，位于 [results](../../experiments/assistant/results/)）：均 3/3 通过，输出均为 `Goodbye.<stopListening/>`。此为 9 次请求的局部复测；上表主结果仍对应修订前提示词，不合并统计。

## 局限

- 单轮合成评估：无多轮结果反馈、无真实 Channel 时长、无 App 上下文；不证明生产 Agent 的端到端效果。
- 仅英文提示词（用户话术含中文）；`zh-Hans` 教学未评估。
- 每 case 仅 3 次重复，百分比差异（如 45/45 与 43/45）在此样本量下不构成模型优劣结论；超时按失败计入，未重试。
- 模型版本字符串按服务商别名调用，未固定快照；`temperature=0` 不保证确定性。
- 真机语音/表情时序体验仍未验证。
