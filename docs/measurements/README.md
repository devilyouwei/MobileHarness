# Device measurements

Purpose: retain bounded raw model/device measurements independently of production SDK implementations; interpretation and acceptance results belong to validation.

提示词回归的合成场景与真实云模型调用证据也保存在本目录，明确区分真实模型输出与设备执行替身。测试方法与结论由 validation 报告维护，原始结果不包含凭据或用户设备数据。

- [Qwen 首轮](qwen-workflow-2026-10-17-run1.json) 与 [修订轮](qwen-workflow-2026-10-17-run2.json) 保留共用场景、各模型实际响应/调用/执行日志/State、请求 hash 和源输入 hash；重复 catalog 按 hash 引用，完整请求保留在报告标注的主机临时文件。首轮未覆盖修订轮新增的确认场景，不能直接把通过率差异视为模型或提示词改善。
- [Native 名称诊断](qwen-native-names-2026-10-17.json) 区分完整提示词的单次额外 replay 与三个最小协议对照；不是原失败响应的完整 wire 捕获，也不解释全部 invalidResponse。结论及逐场景表见 [验证报告](../validation/Qwen-Workflow-Regression.md)。

✅ `nexarm-2026-10-01.csv` contains70 retained small-move trials. `first_within16_seconds=-1` means no hit; negative near-zero times are pre-send receipts and must not count as arrival. A protected stop interrupted the first log; incomplete rows are excluded. Motor6 showed inconsistent tracking and is not calibrated. Motor3 also showed47counts error in a separate raised celebration pose, recorded in ADR0094.

❌ These measurements do not establish full-range/load accuracy or physical safety certification. Re-run supervised measurements before generalizing to other hardware.

✅ `nexarm-gestures-2026-10-01.csv` retains112 motor outcomes: nod/shake-head, the first celebration with the narrower trial profile, and final celebration/dance with motor3 tolerance56. Keeping the failed trial makes the calibration change auditable.

提示词纠正实验已保存 [pilot](qwen-prompt-2026-10-17-pilot1.json)、[首轮完整回归](qwen-prompt-2026-10-17-full1.json)、[最终完整回归](qwen-prompt-2026-10-17-full2.json)及[追加 native-name 探针](qwen-prompt-native-probe-2026-10-17.json)，解释见[优化报告](../validation/Qwen-Prompt-Optimization.md)。每轮保持原始判定；catalog 按语义规范化去重，保留原编码 hash，完整 provider-neutral 请求仍保存在报告标注的主机路径，不声称是 HTTP wire 捕获。

分类异常复现已保留最新代码下同一53场景的[完整三模型结果](qwen-diagnostics-2026-10-17-run1.json)，包括实际失败代码/阶段/名称及完整源码 hash 清单。诊断结果只解释本轮，历史 invalidResponse 不反向补分类；执行仍为替身。

本轮23次失败均为 tool.undeclaredName，详细原因、22次 Action 名称对应关系和1次安全隐藏限制见[复现分析](../validation/Qwen-Diagnostics-Reproduction.md)。


协议对照实验已保留[完整数据](qwen-protocol-comparison-2026-10-17.json)。它与生产53场景不同：语义相同但最小教学及模型侧调用表达受控变化，HTTP公开输出被保存；不执行真实设备，不改变已有失败记录。

[基础 Action 常驻的协议对照](skill-protocol-focused-2026-10-17.json)保留千问 flash/max 的72个 trial、151次请求，以及 GPT‑4.1 首次请求401的访问失败。包含临时脚本和导入脚本源码、完整请求/公开响应、模拟反馈及判定；[分析报告](../validation/Skill-Protocol-Focused-Comparison.md)明确按 Skill 分组不能保证按请求分协议。未上传手机内容。

[生产 Skill 全 Action 完整回归](qwen-all-action-2026-10-17-full1.json)保留 Flash/Max 各53场景、320次模型请求的实际输出/调用/State、规范化请求、原编码 hash、源清单和失败。大字符串通过 textPool 去重；原始判断不改变。[迁移与验收报告](../validation/Skill-Action-Migration.md)区分模型调用、合成执行、自动化、Simulator限制和无签名设备目标构建。

- [2026-10-25提示词复测](prompt-regression-2026-10-25.json)：Qwen三模型完整59场景及GPT-4.1的401诊断；消息语义、实际回复／调用／上下文及源hash持久化。字符串按textPool去重，解释见[验证报告](../validation/Qwen-Workflow-Regression.md#2026-10-25-container-上下文迁移后复测)。

- [NexArm motor teaching experiments](nexarm-robot-teaching-2026-10-27.json): six prompt variants, three real models, synthetic device execution, actual calls/responses and normalized requests with deduplicated strings. See the [validation report](../validation/NexArm-Robot-Skill-Regression.md).
