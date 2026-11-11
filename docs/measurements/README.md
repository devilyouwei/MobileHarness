# Device measurements

Purpose: retain bounded raw model/device measurements independently of production SDK implementations; interpretation and acceptance results belong to validation.

提示词回归的合成场景与真实云模型调用证据也保存在本目录，明确区分真实模型输出与设备执行替身。测试方法与结论由 validation 报告维护，原始结果不包含凭据或用户设备数据。

- [Mac 本地 Decision 模型对照](decision-model-mac-2026-11-11.csv)保留 D3、Laya 和 UniMC 的 456 次逐条判定、分数和时延，方法见[验证报告](../validation/Decision-Model-Mac-Comparison.md)。
- [D3 提示词与句向量对照](decision-request-embedding-2026-11-11.json)保留输入、定义、代表例和 957 次判定，方法见[追加验证](../validation/Decision-Model-Mac-Comparison.md#d3-请求格式与句向量追加对照)。

- [BasicSkill 控制教学](basic-skill-control-2026-11-08.json)：revision 50 两轮 Qwen 回复、调用与失败；保留旧摄影夹具不适配及终轮两项模型失败，解释见[验证记录](../validation/BasicSkill-Control-Teaching.md)。

- [通用 Skill 发现](skill-discovery-2026-11-08.json)：BasicSkill revision 48/49 的 Qwen 实际回复、调用、失败、请求 hash 与相关资源 hash 摘录；完整报告位置保留在数据中，解释见[验证记录](../validation/Skill-Discovery-Before-Denial.md)。

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

Writer 的 2026-11-08 双模型实验保留 [原始基线](writer-prompt-2026-11-08-baseline.json)、[原提示词通信夹具复测](writer-prompt-2026-11-08-baseline-binding.json)和[原提示词及场景快照](writer-prompt-2026-11-08-inputs.json)。真实 Provider + 桌面 WebKit/窗口状态与动画回执替身的边界、结果解释见[Writer 优化报告](../validation/Writer-Prompt-Optimization.md)。PNG 是离线加载真实发布文件的视觉复核，不是模型输入截图。

本轮追加保留 [校准](writer-prompt-2026-11-08-calibrations.json)、[定向一](writer-prompt-2026-11-08-pilot1.json)、[定向二](writer-prompt-2026-11-08-pilot2.json)、[最终完整矩阵](writer-prompt-2026-11-08-full1.json)与[人工复核](writer-prompt-2026-11-08-review.json)。原始自动判定、夹具修正复核与人工事实/视觉评审分开，不反写历史分数。

[仓库验证](writer-prompt-2026-11-08-checks.json)保留 check.sh、四目标 iOS Simulator 构建的退出码、摘要和本机原始日志哈希；构建通过与真实模型断言、人工内容审阅分别计数。

[Writer 执行内聚定向复测](writer-cohesion-2026-11-08-pilot1.json)保留两个模型的七例真实输出；运行时修复归属和平台边界见[验证报告](../validation/Writer-Execution-Cohesion.md)。

[Writer 执行内聚完整矩阵](writer-cohesion-2026-11-08-full1.json)保留两个模型各 30 例的原始断言、工具轨迹、文件及窗口事实，source/binary 冻结校验为 true；结果不等于真机或完整语义验收。

[Writer 执行内聚仓库验证](writer-cohesion-2026-11-08-checks.json)记录自动测试、四目标 iOS 构建、实际文件比对及源指纹；历史提示词实验结果保持不变。

[task.start 初始 Skill 检查记录](task-start-skills-2026-11-08-checks.json)记录专项、全仓检查和四目标构建，以及 BasicSkill/test 指纹；[验证说明](../validation/Task-Start-Initial-Skills.md)区分提示词示例、脚本模型与真机验收。

[task.start 修正版真机安装](task-start-skills-2026-11-08-device.json)记录 iPhone 17 Pro 的 2026110806 覆盖安装、独立版本核对及新包进程启动；不代替模型/交互验收。

- [Writer 记录分页检查](writer-pagination-2026-11-08-checks.json)：分页边界、页面状态回归、完整检查与四目标 iOS 构建；非真机交互验收。

- [task_7 脱敏诊断](writer-task7-2026-11-08-diagnosis.json)：真实两次请求、30 条记录与十段显示的逐行复现；原库留在本机。
