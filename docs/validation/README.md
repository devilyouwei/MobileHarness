# 验证与验收资料

本目录保存验证方法和可追溯证据。报告必须区分替身测试、真实模型、构建、原生 UI 和物理设备，并保留日期、环境、版本、失败与未执行范围。历史报告中的“当前”“默认”“尚未接入”只对应当时版本，不是今天的配置或待办。

## 当前验收入口

| 文档 | 职责 |
| --- | --- |
| [项目验证日志](Validation-History.md) | 按日期记录仓库检查、构建、部署、问题调查与验证结果；专项报告有详细数据时使用链接。 |
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
