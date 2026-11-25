# 新版 quiet 提示词的本地 Decision 对照

## 方法

从 Assistant 当前中英 `QuietExit` 资源冻结无条件和有约定两套提示，快照同时记录来源文件的 SHA-256。Apple 基线使用资源原文与严格 `exit/stay` 解析，原生 Decision 使用相同业务准则改写成布尔问句，`noul > 0.5` 判退出。默认分支只传最新一句，有约定时只传 `wakeCondition`、`latestUtterance` 两个字段。`literal:` 由 App 直接匹配，本次矩阵只评估模型判定。见[冻结提示](../../experiments/decision/quiet-exit-current-prompts-2026-11-25.json)与[运行入口](../../experiments/decision/README.md#quiet-退出判定)。

64 条新编用例覆盖默认邀请、明确授权、直接称名和语义约定四组，每组每语言有 4 条应退出、4 条应保持。场景含直接称呼与转述、延后许可、提及名称、已满足与尚未满足的条件，以及无标点和填充词的合成 ASR 风格语句。用例与标注在推理前冻结，标签不传给模型。每个模型用前两条预热两次，预热不计入指标，再按同一顺序执行全部 64 条，单请求上限 30 秒。见[评估集](../../experiments/decision/datasets/quiet-exit-current-cases-2026-11-25.json)。

环境为 Apple M5、16 GiB、macOS 27.2.1（26B131）、Python 3.13.13、Core AI 1.0.0b3、Transformers 5.17.0、Apple FM SDK 0.2.2。原生模型复用已下载制品，按实验适配器现有校验验证。D3 Edge 校验图 SHA-256，Vela 3 Fast、Vela 3.1 Fast 与 Laya 逐文件校验各自清单，Laya 另校验 host wheel。Vela 3.1 的 Python SDK 来自本机仓库的固定提交 `2e19add705d3f3e88620d70acd7a5613c3a17a23`。各后端在独立进程中串行运行。

| 本地制品 | 固定修订 | 实验适配器执行方式 |
| --- | --- | --- |
| D3 Edge | `0690c04ee1640c1c3fa11a882323751dda6d086a` | Core AI 默认 specialization |
| Vela 3 Fast | `6aaa9ccd747c4bad65037979e7f9373a76fb7683` | CPU |
| Vela 3.1 Fast | `108e385769cbd0da463706b24cac5a535604d2c6` | CPU |
| Laya Multilingual | `3fe58a5ed7857b41f5c7ba8c0f46ce420b42cf02` | macOS WFP16 S512，GPU |

## 结果

五个后端全部完成，每个 64 条正式请求、2 条预热，共 320 条计分请求和 10 条预热。全部返回有效 verdict，无推理错误、超时或未执行用例。运行器在任一标签不匹配时返回非零，五个后端各自的退出码均为 1，批次退出码为 1。

| 模型与原始输出 | 正确 | 误唤醒 / 32 | 漏退出 / 32 | p50 / p95（ms） |
| --- | ---: | ---: | ---: | ---: |
| [D3 Edge](../../experiments/decision/results/quiet-exit-current-d3-edge-2026-11-25.json) | 40/64 | 9 | 15 | 182 / 315 |
| [Vela 3 Fast](../../experiments/decision/results/quiet-exit-current-vela3-fast-2026-11-25.json) | 40/64 | 10 | 14 | 959 / 1738 |
| [Vela 3.1 Fast](../../experiments/decision/results/quiet-exit-current-vela31-fast-2026-11-25.json) | 39/64 | 9 | 16 | 1590 / 3464 |
| [Laya Multilingual](../../experiments/decision/results/quiet-exit-current-laya-2026-11-25.json) | 32/64 | 24 | 8 | 145 / 192 |
| [Apple 系统模型](../../experiments/decision/results/quiet-exit-current-apple-system-2026-11-25.json) | 43/64 | 8 | 13 | 709 / 1086 |

下表单元格为误唤醒数 / 漏退出数。每组有 8 条应保持和 8 条应退出。

| 模型 | 默认邀请 | 明确授权 | 直接称名 | 语义约定 |
| --- | ---: | ---: | ---: | ---: |
| D3 Edge | 1 / 5 | 0 / 4 | 7 / 1 | 1 / 5 |
| Vela 3 Fast | 3 / 7 | 0 / 2 | 7 / 0 | 0 / 5 |
| Vela 3.1 Fast | 2 / 7 | 0 / 3 | 7 / 0 | 0 / 6 |
| Laya Multilingual | 4 / 4 | 8 / 0 | 8 / 0 | 4 / 4 |
| Apple 系统模型 | 3 / 6 | 1 / 1 | 2 / 2 | 2 / 4 |

下表分语言列出误唤醒数 / 漏退出数。每种语言有 16 条应保持和 16 条应退出。

| 模型 | 中文 | 英文 |
| --- | ---: | ---: |
| D3 Edge | 4 / 10 | 5 / 5 |
| Vela 3 Fast | 7 / 8 | 3 / 6 |
| Vela 3.1 Fast | 6 / 10 | 3 / 6 |
| Laya Multilingual | 16 / 0 | 8 / 8 |
| Apple 系统模型 | 1 / 10 | 7 / 3 |

## 对共用 Decision 的意义

- D3 Edge 在本地模型中兼顾了较低延迟与较低误唤醒数。在默认邀请组，D3 误唤醒 1/8，漏掉 5/8，Apple 为 3/8、6/8。D3 可作为默认邀请的候选继续验证，当前召回仍不足以全量接管。
- 直接称名是四个原生模型共同的失败点，8 条负例中误放行 7 到 8 条。错误覆盖了提及名字、转述叫名和喊错名字。四个模型在该组的最高负例分数都高于最低正例分数，用一个阈值无法把该组样本全部分开。
- 明确授权和语义约定需要分别看。D3 和两款 Vela 对明确授权组均无误唤醒，仍各漏 2 到 4 条。对“条件已经发生”的语义约定则漏 5 到 6 条，比如重述同一个已发生事件时仍可能给出 stay。Laya 虽然最快，但中文 32 条全部预测为退出，包含全部 16 条中文负例。
- 这些数据支持共用 provider 与推理资源的方向，暂不支持让单一本地模型决定所有 quiet 退出。若继续验证共享方案，可优先用真实 ASR 复测 D3 的默认邀请，分别检查称名和语义约定，再衡量 App 里的排队与端到端延迟。

## 范围与校验

延迟为 Mac 上排除预热后的单请求时间，包含 Python 请求构造与模型调用，各后端使用的计算单元不同。用例为新编合成文本，部分模拟无标点 ASR；每组每语言只有 8 条，模型各运行一次。旧实验与本次的数据、提示和请求结构均有变化，因此两轮结果无法用来估计单独更新提示词带来的提升。App、真机、真实 ASR、云端和 interrupt 判定本轮未测。

Python 实验离线回归通过 35 项。另逐条复算 320 条预测、统计与分语言指标，核对请求正文、输入和提示快照的 SHA-256，以及用例与旧评估集没有重复句。工程构建及 Swift 测试未在本次实验中执行。
