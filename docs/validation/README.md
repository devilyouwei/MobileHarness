# 验证与验收资料

本目录保存验证方法和可追溯证据。报告必须区分替身测试、真实模型、构建、原生 UI 和物理设备，并保留日期、环境、版本、失败与未执行范围。历史报告中的“当前”“默认”“尚未接入”只对应当时版本，不是今天的配置或待办。

## 当前验收入口

| 文档 | 职责 |
| --- | --- |
| [Agent containers](Agent-Containers.md) | Root/role ownership, lifecycle regression, build evidence and independent native acceptance. |
| [Agents / Actions 组织整理](Agents-Actions-Organization.md) | 目录归属、共享机制与端点解耦的回归、模拟器编译和原工程文件协调限制。 |
| [外部输入直连 Container](Direct-Container-Input.md) | 直连迁移的自动检查、锁定依赖构建、设备修正版安装及尚未完成的原生／性能验收。 |
| [项目验证日志](Validation-History.md) | 按日期记录仓库检查、构建、部署、问题调查与验证结果；专项报告有详细数据时使用链接。 |
| [千问工作流回归](Qwen-Workflow-Regression.md) | 同套合成场景下真实 flash/plus/max 的 Action/Tool、Task/Skill 调用与边界；不等于物理设备验收。 |
| [千问提示词修订回归](Qwen-Prompt-Optimization.md) | 基于原始失败修订教学后的同用例对照，保留 pilot、完整运行及残留失败；不改执行权限。 |
| [连续动作提示词验证](Action-Sequence-Prompts.md) | 串行动作、组内语音/表情并行的生产示例与预算回归；包含 Flash/Max 三轮专项及完整原始数据，保留完整检查、构建与原生效果验收限制。 |
| [语音验收指南](Voice.md) | 当前可重复的语音体验检查步骤及记录要求，不固定某次模型默认或宣称已经通过。 |
| [NexArm 物理试验](NexArm_Physical_Acceptance.md) | 带日期的真实硬件调查和测量，限定 USB/BLE、设备、负载和观察范围。 |
| [原始测量数据](../measurements/README.md) | 保留原始 CSV 与字段解释；测量值和失败样本不因文档整理改变。 |

## 专项历史报告

| 报告 | 证据范围 |
| --- | --- |
| [代码 README 验证摘录](Code-README-Validation-History.md) | 从代码目录迁出的测试、构建、安装与验收原文；保留原日期和限制，不作为当前通过状态。 |
| [MOSS](Moss-Validation.md) | 2026-09-28 的 Mac/短时 iPhone 合成、播放故障及容量调整记录。 |
| [Nemotron](Nemotron-Validation.md) | 早期 CoreAI 接入与 2026-10-03 Core ML 制品替换，分阶段解释。 |
| [Silero](Silero-Validation.md) | 2026-09-23 的真实 VAD、分片及识别组合验证。 |
| [Kokoro](Kokoro-Validation.md) | CoreAI 英语与 Core ML 中英实现的旧测试和未完成验收；不代表当前默认。 |
| [Audio8](Audio8-Validation.md) | 已移除适配器的历史验证，旧下载/测试入口不保证仍可执行。 |
| [初始化](Bootstrap-Validation.md) | 2026-09-22 工具链、最初测试与环境限制快照。 |

## 证据与当前契约

模型选择、默认值、资源安装、超时和容量由 [ModelKit](../../MobileHarness/ModelKit/README.md)、[App](../../MobileHarness/App/README.md) 与所属模块 README 维护，报告不重复一份会漂移的当前配置。执行旧复现步骤前核对现有源码、脚本和制品版本；文中命令以仓库根目录为工作目录。

项目日志记录跨模块检查的经过，专项报告保留模型/设备实验的详细样本和测量。相同实验通过链接复用，不能把多个报告中的相同运行合计为更多次验证。历史失败不删除，新的成功也不追溯改写旧结果。

[当前验收方向](../Roadmap.md#acceptance-work) · [文档总索引](../README.md) · [历史资料](../history/README.md)

[分类异常复现分析](Qwen-Diagnostics-Reproduction.md) 使用新增类型化诊断复跑同套场景，区分协议原因、流程判定和执行替身，不改变原判定。


[调用协议对照](Qwen-Protocol-Comparison.md) 区分请求同时提供两类能力、同一响应混用和跨轮分开使用，覆盖 flash/max 与隔离语法对照。

[基础 Skill 常驻时的协议对照](Skill-Protocol-Focused-Comparison.md)比较同 Skill 混合、分 Skill 混合与全 Action；千问 flash/max 小范围实验完成，GPT‑4.1 首次请求返回401，未得到模型输出。不改生产注册。

[内置 Skill 全 Action 迁移](Skill-Action-Migration.md)记录生产注册、Query Channel、原生 Tool 基础能力保留，以及完整 Flash/Max 工作流的实际结果、残留失败和构建边界。早期隔离实验不作为本次生产迁移的验收替代。

- [PlatformKit 容器与设备接入验证](PlatformKit-Containers.md)

- [Direct container input validation](Direct-Container-Input.md): automated/build evidence and outstanding physical/performance checks.
