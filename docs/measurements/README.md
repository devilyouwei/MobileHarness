# Device measurements

Purpose: retain bounded raw model/device measurements independently of production SDK implementations; interpretation and acceptance results belong to validation.

提示词回归的合成场景与真实云模型调用证据也保存在本目录，明确区分真实模型输出与设备执行替身。测试方法与结论由 validation 报告维护，原始结果不包含凭据或用户设备数据。

- [Mac 本地 Decision 模型对照](decision-model-mac-2026-11-11.csv)保留 D3、Laya 和 UniMC 的 456 次逐条判定、分数和时延，方法见[验证报告](../validation/Decision-Model-Mac-Comparison.md)。
- [D3 提示词与句向量对照](decision-request-embedding-2026-11-11.json)保留输入、定义、代表例和 957 次判定，方法见[追加验证](../validation/Decision-Model-Mac-Comparison.md#d3-请求格式与句向量追加对照)。
- [全双工小模型 Core AI 对照](duplex-llm-coreai-2026-11-13.json)保留逐条候选分数、时延、制品版本和复现脚本，方法见[验证记录](../validation/Decision-Model-Mac-Comparison.md#小参数生成模型的-core-ai-对照)。
- [全双工对话历史窗口 Core AI 对照](duplex-history-coreai-2026-11-13.json)保留同句异义样例、四款制品在各窗口的原始分数、超时和复现脚本，方法见[验证记录](../validation/Decision-Model-Mac-Comparison.md#对话历史窗口对照)。
- [2、4、8、10 条历史窗口续测](duplex-history-windows-coreai-2026-11-13.json)保留 9 款 Core AI 制品的历史窗口对照、超限终止和复现脚本，方法见[验证记录](../validation/Decision-Model-Mac-Comparison.md#24810-条历史的续测)。
- [Decision 动作定义与示例](duplex-decision-prompt-examples-2026-11-13.json)保留两版英文提示词、46 条合成输入、逐条标签及延迟汇总。 [验证记录](../validation/Decision-Model-Mac-Comparison.md#三种动作定义与对照示例)
- [D3 输入边界与双语示例](duplex-d3-bilingual-examples-2026-11-13.json)保留 512 token 边界、17 个双语变体、24 条新增探测及逐条预测和延迟。 [验证记录](../validation/Decision-Model-Mac-Comparison.md#d3-输入边界与双语示例)
- [D3 防止误丢弃](duplex-d3-discard-protection-2026-11-14.json)保留两版提示词、20 条新增样例、原始模型输出和采纳规则离线回放。 [验证记录](../validation/Decision-Model-Mac-Comparison.md#保留明确指令和可能有效的转写)
- [D3 中英文打断近义词](duplex-d3-interrupt-synonyms-2026-11-14.json)保留 50 个配置的汇总、34 条新增探测及代表配置的逐条测量。 [验证记录](../validation/Decision-Model-Mac-Comparison.md#中英文打断近义词)
- [Decision prompt language split](decision-language-d3-2026-11-14.json) contains native D3 output, adopted dispositions, rendered requests and timings for the [paired scenarios](decision-language-scenarios-2026-11-14.json) and separate context probes. [Validation report](../validation/Decision-Model-Mac-Comparison.md#decision-prompt-language-split)

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
- [全双工本地 LLM 输出格式对照](duplex-llm-output-formats-coreai-2026-11-14.json)保留 24 组完整运行、逐条结果及复现脚本。方法见[验证记录](../validation/Decision-Local-LLM-Output-Formats.md)。
- [全双工本地 LLM 中英文数字提示词对照](duplex-llm-bilingual-digits-coreai-2026-11-14.json)保留 10 组完整运行、逐条数字输出及复现脚本。方法见[验证记录](../validation/Decision-Local-LLM-Bilingual-Digits.md)。

- [D3 Edge 中英文数字提示词对照](duplex-d3-bilingual-digits-coreai-2026-11-14.json)保留 5 组共 500 次原生 Choice、逐条得分及复现脚本。方法见[验证记录](../validation/Decision-Local-LLM-Bilingual-Digits.md#d3-edge-同批对照)。
- [全双工本地 Decision 去掉动作定义的对照](duplex-local-no-action-definitions-coreai-2026-11-14.json)保留 14 组简化提示、D3 旧提示对照、逐条结果及与有定义版本的差值。方法见[验证记录](../validation/Decision-Local-LLM-Bilingual-Digits.md#去掉动作定义的对照)。
- [历史对话与缓冲区提示词对照](duplex-history-buffer-prompt-coreai-2026-11-14.json)保留 36 条用例在 D3 与 Qwen2.5 的中英文实际提示及逐条读出。方法见[验证记录](../validation/Decision-Local-LLM-Bilingual-Digits.md#历史对话与缓冲区格式复测)。
- [D3 Lite 与 Edge 的四段提示对照](duplex-d3-lite-edge-coreai-2026-11-15.json)保留当前中英文提示和旧短中文提示共 200 条原生分类，方法见[验证记录](../validation/Decision-Model-Mac-Comparison.md#d3-lite-与-edge-的四段提示对照)。

- [Apple system Decision experiment attempt](decision-apple-system-2026-11-15.json): 154 prepared requests, exact archived baseline predictions, current renderer output, hashes and host availability. This run is blocked (`deviceNotEligible`), with zero measured Apple requests; it contains no Apple accuracy or latency result.

- [Apple 系统模型 M5 Decision 完整复跑](decision-apple-system-m5-2026-11-15.json)保留 Apple 154 条真实生成、Edge/Lite 同机各 154 条原生读出、冻结预测核对及复现代码。 [验证报告](../validation/Decision-Model-Mac-Comparison.md#m5-mac-完整复跑)

- [Gemma 4 E2B M5 Decision 对照](decision-gemma4-m5-2026-11-15.json)保留同一组 54 条中英文样例的两种请求格式、108 条真实生成、预热、各阶段计时及源文件哈希。生产路径提供设置页评分，格式指令内联组仅用于诊断。 [验证报告](../validation/Decision-Model-Mac-Comparison.md#gemma-4-e2b-decision-comparison)
- [Qwen Flash Decision 三协议对照的云端组](decision-protocols-cloud-2026-11-15.json)保存两款 Flash 模型的 Tool 和纯文本 216 条同构用例结果、延迟和错误分类。 [验证报告](../validation/Decision-Model-Mac-Comparison.md#assistant-decision-protocol-benchmark)
- [Assistant Decision 三协议本地组](decision-protocols-local-2026-11-15.json)保存 D3 Edge、D3 Lite、Apple 和 Gemma 共 270 条实测、模式分组及预热记录。 [验证报告](../validation/Decision-Model-Mac-Comparison.md#assistant-decision-protocol-benchmark)

[D3 Lite hugging-mac report](d3-lite-hugging-mac-2026-11-15.json) records the 54 matched bilingual JEV requests for the App's replacement artifact, with its release revision and graph hash.

- [A18 Pro Mac D3 复测（2026-11-15）](decision-d3-a18-mac-2026-11-15.json)：Edge/Lite 各54条生产协议评分、加载/缓存后预热日志、制品与源码哈希；方法与限制见[专项报告](../validation/Decision-Model-Mac-Comparison.md#a18-pro-mac-最新代码复测2026-11-15)。

- [iPhone Lite loading 现场摘要（2026-11-15）](decision-d3-lite-iphone-loading-2026-11-15.json)：手机制品核对、App专属CPU资源报告指标、D3加载到ANE编译的符号化调用链及采集限制；不含原始设备诊断包。

- [D3 iOS AOT build inventory](decision-d3-ios-aot-2026-11-15.json): h18p Edge/Lite compile provenance and file hashes; upload and device acceptance status are explicit.

- [D3 Lite iOS AOT native load crash](decision-d3-lite-ios-aot-crash-2026-11-15.json): two matching device crash stacks and all installed file hashes, distinct from successful Mac compilation.

- [D3 Edge 继续聆听四分类汇总（2026-11-16）](decision-continue-listening-summary-2026-11-16.json)：[194条冻结样例](decision-continue-listening-scenarios-2026-11-16.json)、[App实际提示/期限/采纳](decision-continue-listening-d3-edge-2026-11-16.json)、[无Assistant期限的原生读出](decision-continue-listening-readout-2026-11-16.json)及[制品/主机哈希](decision-continue-listening-artifact-2026-11-16.json)。仅D3 Edge；语义评分与容量/持有探测分开。见[实验报告](../validation/Decision-Model-Mac-Comparison.md#d3-edge-继续聆听四分类实验2026-11-16)。

- [D3 Edge 提示词优化（仅实验环境）](decision-prompt-optimization-summary-2026-11-16.json)：11组开发对照、[第二阶段汇总](decision-prompt-optimization-refined-summary-2026-11-16.json)、[48条预冻结留出复核](decision-prompt-optimization-holdout-summary-2026-11-16.json)及[入选模板](decision-prompt-optimization-template-2026-11-16.json)。完整请求、选型依据和限制见[报告](../validation/Decision-Model-Mac-Comparison.md#d3-edge-提示词结构优化实验2026-11-16仅实验环境)。

- [D3 Edge 真机 discard 反馈复核](decision-discard-recheck-summary-2026-11-16.json)：现场完整请求回放、单独替换 B 候选及原48条留出复测；输入和结果见[原对照报告](../validation/Decision-Model-Mac-Comparison.md#真机-discard-反馈复核2026-11-16-2205)。

- [精简 App JEV 请求](decision-minimal-app-input-2026-11-16.json)与[六条 D3 Edge 原始结果](decision-minimal-app-results-2026-11-16.json)：仅utterance/busy及四类定义，接入与安装见原Mac报告。

- [D3 Edge 源图切换文件核对（2026-11-17）](decision-edge-source-rollback-parity-2026-11-17.json)：固定HF revision与Mac本地12个对应文件内容匹配；App下载配置切换见[D3制品记录](../validation/D3-iOS-AOT.md#edge-source-package-selection-restored--2026-11-17)。

- [Vela3 Fast / D3补充对照](decision-vela-d3-summary-2026-11-17.json)：两模板的Vela108条请求，D3本轮失败与历史准确率分开，见[原Mac报告](../validation/Decision-Model-Mac-Comparison.md#vela3-fast-本地补充对照2026-11-17)。

- [第三方D3 Edge制品配置证据](decision-alternative-edge-artifact-2026-11-17.json)：maxffarrell固定版本、五输入接口及远端元数据哈希；[Hello原样回放](decision-hello-phone-replay-results-2026-11-17.json)记录原制品Mac三次discard。

- [discard边界两轮对照](decision-discard-refinement-summary-2026-11-17.json)：自有D3 Edge、440条评分；单条Hello改善不能替代整体质量，本轮无生产提示迁移。

## Decision 打断意图二分类

- [二分类打断输入](decision-binary-input-2026-11-17.json)：[D3汇总](decision-binary-d3-summary-2026-11-17.json)、[Vela汇总](decision-binary-vela-summary-2026-11-17.json)，方法及原始数据见[对照报告](../validation/Decision-Binary-Interrupt-Mac-Comparison.md#二分类打断意图对照2026-11-17)。

- [本地化noul/choice溯源](decision-localized-binary-provenance-2026-11-17.json)：两模型1960次、每语言80主样例及跨语种/混合/歧义边界；[D3汇总](decision-localized-binary-d3-summary-2026-11-17.json)、[Vela汇总](decision-localized-binary-vela-summary-2026-11-17.json)，完整输入/原始数据和指标见[扩展报告](../validation/Decision-Binary-Interrupt-Mac-Comparison.md#本地化-noul-与-choice-扩展实验2026-11-17)。

- [历史上下文二分类溯源](decision-history-binary-provenance-2026-11-17.json)：独立于单句测试，最多4轮历史＋当前轮次，两模型2240次；[D3汇总](decision-history-binary-d3-summary-2026-11-17.json)、[Vela汇总](decision-history-binary-vela-summary-2026-11-17.json)，完整矩阵、原始数据和容量探针见[报告](../validation/Decision-Binary-Interrupt-Mac-Comparison.md#历史上下文二分类独立实验2026-11-17)。

App 二分类 Swift 接入：[原始记录](decision-binary-app-native-2026-11-17.json)、[汇总](decision-binary-app-native-summary-2026-11-17.json)、[Vela Python 对照](decision-binary-app-vela-parity-2026-11-17.json)。解释见[二分类验证](../validation/Decision-Binary-Interrupt-Mac-Comparison.md#2026-11-17-app-二分类-swift-接入验证)，不代表手机验收。
