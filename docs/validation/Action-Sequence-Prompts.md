# 连续动作提示词验证

日期：2026-10-18。范围为 Core 通用编排教学、常驻 ExpressionInteraction 教学及生产示例回归；不修改解析器、调度器、设备执行或模型供应商配置。

## 教学与自动化证据

- Core scheduling 区分完整串行 A/B/C/D 与“组内并行、各组串行”，要求一次响应展开已确定的全部步骤；结果依赖和独占调用规则仍适用。
- ExpressionInteraction revision 12 提供三项纯串行示例和全部 11 种 express 表情的逐项报名称示例。每项独立 wait，保持默认 Speech/Display Channel；clear 不作为可演出表情。
- `expressionSequenceTeachingUsesSerialGroupsAndParallelSpeech` 从实际打包资源读取示例，用生产目录和逐字符增量解析验证合法性、分组、顺序、语音/字幕与表情对应、默认 Channel、全量枚举覆盖以及默认请求包含教学。
- 最终定向命令：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'expressionSequenceTeaching|assistantInstructionBudgets'`，2 项通过。日志：`/tmp/mobileharness-sequence-prompts-targeted.log`。
- 最终静态 system 为基础 23,153 / 含摄影 30,442 UTF-8 bytes。为新增通用教学及完整表情示例，两个测试预算各增加 1,500 bytes，成为 23,500 / 30,500；生产完整请求仍受 64KiB 限制。

## 完整检查与构建限制

执行了 `./scripts/check.sh`，退出 1，不能视为全量通过。边界检查、6 项 Python 测试和 Swift 格式检查通过；生产示例、提示词装配及现有 `waitGroupsJoinBeforeAndAfterWithoutBlockingIndependentTasks`、`nestedWaitIsStreamingButUnclosedGroupCannotReleaseParentContinuation` 通过。

完整检查的最后一次运行仍使用精简前的中间提示词：长度 23,330 / 30,619，摄影预算断言失败。进一步精简后的最终定向测试已通过，未将旧完整检查追溯改写为通过。完整检查还报告以下未在本次提示词范围内修改的失败：

- `cameraNativeMetalDrawStopAndLayerHandoff`：原生 Metal 呈现等待断言失败。
- `atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError`：2 秒时限断言失败。
- 7 项 SoundSource 用例：感知等待超时及后续状态断言失败。

日志：`/tmp/mobileharness-sequence-prompts-check.log`。这些是当前混合工作区的观察结果；未做干净基线对照，不据此归因于本次修改。

执行了 `./scripts/build-ios.sh`，退出 65。首个 MobileHarnessSimulator scheme 在依赖 `coreai-models/CoreAIShared/Runtime/ModelStructure.swift:6` 无法解析 `CoreAI`，arm64/x86_64 均失败；脚本随后中止，未完成其余 scheme。日志：`/tmp/mobileharness-sequence-prompts-ios.log`。

## 最初离线阶段的未验收范围

最初离线阶段未调用真实千问 Flash 或其他云模型，未进行真实语音、原生表情动画或物理设备验收。解析分组和既有调度器回归通过不等于模型会遵循教学；组内并行也不承诺语音和动画精确同刻开始。后续真实模型结果单独记录如下，不追溯改写离线证据。

## Flash / Max 真实模型专项

同日按用户授权复用 `.env.local` 与 `scripts/evaluate-qwen.py`，通过生产 Assistant、提示词、函数目录、增量解析器和 Gateway 调度运行；设备、仓库和语音执行仍为明确的合成替身。原有 53 个场景保持原文和判定，新增 6 个 expression-sequence 场景，本次只选择这 6 个专项，不代表全部 59 场景回归。

每个模型执行三轮独立采样，每轮每场景使用独立会话；改序场景包含两个用户输入，其余各一个。共 36 次场景运行、42 个用户输入、42 次真实模型请求，无自动重试或换模型。三轮执行前后源 hash 一致，三轮之间也一致；采样期间未修改提示词或判定。

| 场景 | 核对重点 | Flash | Max |
| --- | --- | --- | --- |
| expression-serial-four | 开心→思考→惊讶→微笑，静默串行 | 3/3 | 3/3 |
| expression-serial-all | 全部 11 种表情各一次，无语音 | 3/3 | 3/3 |
| expression-paired-three | 开心→思考→惊讶，每项语音/表情同组 | 3/3 | 3/3 |
| expression-paired-all | 全部 11 种表情逐项介绍，每项独立 wait | 3/3 | 3/3 |
| expression-paired-reordered | 调皮→害怕→生气→微笑；下一轮反序且静默 | 3/3 | 3/3 |
| expression-paired-keeps-task | 难过→喜爱→大笑，介绍完保留原照片 Task | 3/3 | 3/3 |
| 合计 | 每模型 18 场景、21 请求 | **18/18** | **18/18** |

原问题的全量介绍场景中，两款模型三轮都输出 11 个独立 wait，每组对应一个 express 和名称语音，使用默认 Display/Speech Channel。每个模型共生成 120 次表情、63 段介绍语音。测试同时检查顺序/集合、数量、名称、组路径、同轮完整输出、无多余 Task/Skill 控制及 Task 保留；全量未指定顺序时允许枚举重排，名称接受预先定义的常用中英文同义词。

纯静默的同 Display Channel 本身就保证串行，不要求模型添加冗余 wait。介绍版要求每项单独 wait，语音和表情同组且保持各自默认 Channel。新增记录器用合成语音请求还原 audioID 对应的文本，只增加证据，不改送往 Gateway 的实际输出。离线评分回归包含 8 个变体，验证合法/嵌套/静默输出与错组、错名称、漏项、无 wait、顺序错误；连同用例合法性检查通过。

### 数据与复现

[完整数据 JSON](Action-Sequence-Flash-Max-2026-10-18.json) 保存三轮六份原始模型报告、每次实际请求消息、模型原文、已解析调用与 waitPath、State、用量、测试日志、源 hash、场景规格和教学快照。已检查不含本地 API Key。实际使用阿里云配置，不读取或发送 OpenAI Key。

| 用量 | Flash | Max |
| --- | --- | --- |
| 模型请求 | 21 | 21 |
| 输入 token | 111,597 | 111,597 |
| 其中缓存输入 token | 83,968 | 88,192 |
| 输出 token | 1,572 | 1,560 |

先执行离线构建/评分检查，再将下面命令的输出前缀依次换成 r1、r2、r3；脚本拒绝覆盖已有原始输出。`--skip-build` 只复用已经完成的本地编译，真实云调用仍实际执行。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'qwenWorkflowCasesAreBoundedAndUseRegisteredAliases|qwenExpressionSequenceScoringRejectsBrokenGroups'
python3 scripts/evaluate-qwen.py \
  --models qwen3.8-flash qwen3.8-max \
  --cases expression-serial-four,expression-serial-all,expression-paired-three,expression-paired-all,expression-paired-reordered,expression-paired-keeps-task \
  --parallel 2 --skip-build --output-prefix /tmp/qwen-expression-20261018-r1
```

原始临时文件仍在 `/tmp/qwen-expression-20261018-r{1,2,3}*`，永久 JSON 已包含原始报告，不依赖这些临时文件才能审查结果。

### 本轮仓库检查与边界

`./scripts/check.sh` 已运行，退出 1。新增离线回归、用例合法性、提示词预算及结构回归通过；完整检查还报告相机 Metal 呈现、机械臂 2 秒时限、蓝牙恢复、7 项声源用例和媒体过期显示用例失败。日志 `/tmp/mobileharness-expression-eval-check.log`，原始失败条目已保存在完整数据 JSON；不将局部通过描述为全量通过，也未做干净基线归因。

`./scripts/build-ios.sh` 已运行，退出 65，仍在 CoreAIShared 无法解析 CoreAI 处失败；首个 scheme 失败后其余 scheme 未执行。日志 `/tmp/mobileharness-expression-eval-ios.log`，错误原文保存在完整数据 JSON。

本次证明当前提示词在这组真实模型样本中通过判定；未运行旧提示词对照，不能据此量化改进幅度或保证所有输入都可靠。真实语音播放、动画持续时间与听说竞争未验收，组内并行不承诺精确同刻开始。
