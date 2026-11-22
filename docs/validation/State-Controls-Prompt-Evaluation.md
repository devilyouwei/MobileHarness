# State 泛化后的控制提示词评估（qwen3.8-flash）

对应设计：[State 泛化与 Task 去除](../requirements/technical/State-Generalization-Task-Removal.md)、[ADR 0220](../adr/0220-agent-state-generalization.md)。

## 方法

- 运行器：[evaluate_qwen.py](../../experiments/assistant/evaluate_qwen.py)，纯 Python，合成动作反馈，不连接设备也不运行 App。模型 qwen3.8-flash，temperature 0，请求上限 16，单 case 超时 120 秒。
- 提示词：[assistant-evaluation.json](../../experiments/assistant/assistant-evaluation.json) 内含生产 Controls.md 的冻结副本（来源哈希在 `controlsSource`）、AGENT STATE VARIABLES 声明块，以及每轮用户输入前的独立 AGENT STATE system 块。
- 合成状态机（[workflow_scoring.py](../../experiments/assistant/workflow_scoring.py)）镜像 App 规则：`state.set/clear/send` 成功无返回、失败返回原因；`quiet` 只读；`task` 已有值时替换或清除必须带 `note`；名字必须是无命名空间的短名；`state.get` 总有返回值。
- 数据集：[qwen-workflows.json](../../experiments/assistant/datasets/qwen-workflows.json) v2。旧 84 个 case 迁移到新控制名；新增 9 个 case（语义变量、风格、可见值不重复读取、读其他来源、只读拒绝、命名空间拒绝、`quiet` 下不主动写、清除带 note、多轮设置/旁白/清除）。
- 对照：同一模型、同一参数运行 HEAD（旧 `task.*`/`loadSkills` 提示词与旧数据集）一次。

## 结果

| 运行 | 文件 | 通过 / 总数 | 超时错误 |
| --- | --- | --- | --- |
| 旧设计基线 | [task-controls-baseline-head-qwen3.8-flash-2026-11-22.json](../../experiments/assistant/results/task-controls-baseline-head-qwen3.8-flash-2026-11-22.json) | 30 / 84 | 5 |
| 新设计 run1 | [state-controls-qwen3.8-flash-2026-11-22-run1.json](../../experiments/assistant/results/state-controls-qwen3.8-flash-2026-11-22-run1.json) | 49 / 93 | 2 |
| 新设计 run2（提示词增加自闭合标签格式一句） | [state-controls-qwen3.8-flash-2026-11-22-run2.json](../../experiments/assistant/results/state-controls-qwen3.8-flash-2026-11-22-run2.json) | 48 / 93 | 2 |

分类：state 8/8（两次）；task 9/11 与 10/11（基线 1/9）。两次运行之间有 13 个 case 通过与否互换，多为 Skill 冷启动、重试和云端超时，说明单次结果波动明显，不能据此排名。

## 发现

- 新增 state 与 task 的 case 在两次运行中稳定通过：模型能用 `state.set` 记录 mood/风格，已在 AGENT STATE 可见时不重复 `state.get`，被拒绝的只读/带命名空间写入不会改变值。
- 未发现新提示词导致的系统性回归。基线 task 类很低，主要是旧提示词没有教学，而不是新设计更好的证据。
- 观察到的行为风险：
  - 用户说“全程不要说话”时，模型曾写只读 `quiet`，被拒绝后继续执行（符合设计，但说明 `quiet` 的措辞会诱导模型尝试写入）。
  - 模型会在用户只是陈述心情时自发写 `mood`（`task-skill-survives-asides`），并在模糊的“暂时保留”下清除了 `task`；需要真实 App 提示词和更多样本再判断。
  - 回复文字里复述 `<closeCamera/>` 会被评分器当作调用（`tool-result-injection`），是评分器对解析文本的局限，不是模型执行了该动作。

## 限制

- 一个模型、每个设定仅 1–2 次运行；temperature 0 的云端模型仍有波动。机器人、表情序列、蓝牙等类别在实验提示词缺少对应 Skill 正文时通过率低，基线与新设计均如此，不属于本次变更。
- 实验提示词不是 App 请求的逐字复刻（无 Skill 正文、无 CURRENT STATE）。真机、全双工路径、其他模型（含本地模型）未验证。
- 未更新 `evaluate_prompts.py`、`compare_qwen_protocols.py`、`evaluate_wait.py` 的数据集，它们是否仍引用旧名称未在本次检查。
