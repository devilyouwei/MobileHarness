# 任务评估集与共享制品整理验证

日期：2026-11-18。

34 份原 docs/measurements 独立输入/场景/留出集迁入任务 Datasets，文件 SHA-256 全部与迁移前一致。原 Assistant、Writer 场景及 Decision benchmark fixtures 同归所属任务。混合报告和实际响应、时延、汇总仍在 docs/measurements，历史 JSON 中的来源路径与哈希不改写。

4 个现有本地模型目录 D3Edge、LayaMultilingual、Vela31Fast、Vela3Fast 从 benchmark/.local/models 移至根 Models；更新 Python 默认制品根和 Swift 评估入口。Gemma Mac 下载器输出 Models/Gemma4，Tests 可通过既有资源环境变量共享。根 Models 子目录均被 Git 忽略。

已通过：34 份哈希与 JSON 核对、Python语法、任务文档本地链接、CLI 帮助、17 个 Python 离线用例。Xcode Tests/experiments 导航的341份文件引用反映新布局。Swift 两处长路径格式已修正。

iOS 构建退出 0，5 个 Simulator scheme 全部通过。18 个测试 target 的依赖、函数和 gate 核对通过，184 份 Swift 编译源保持唯一归属。完整 check 的 Swift 编译通过；普通 IntegrationTests 1198 个测试有7个 issue：三处英文提示词断言、跟踪目标时序断言，以及 assistantExecutesRobotActionWithoutDelegation 的 expired、writerAcceptsTwentyTasksWithAllUserNotificationsRejectedThenRestoresOnlyDelivery 和 writerOwnsTargetSelectionAndCompletion(switch-after-edit) 的 incomplete。本轮新增出现的运行时失败不被声称为迁移前已验证。

AppWorkflow 再现模型列表断言、injected Action declarations 缺失与 writerCancellationDuringBackoffDoesNotStartAnotherRequest 无截止等待，已终止仅该测试子进程，阶段未完整运行。串行 LiveRuntimeTests 228 个测试、1 个 soundSourceSlowSubscriberDoesNotBlockFollowingDirections 超时 issue。NativePresentationTests 没有完整汇总，不宣称通过。最终五个 plist/project 检查通过；scripts/check.sh 退出 1，不能记为全量通过；不启用真实模型或云服务 gate，目录核对与构建不能代替模型、原生 UI 或设备验收。

本机临时日志：`/tmp/mh-task-datasets-check.log`、`/tmp/mh-task-datasets-ios.log`。最终设计见 [整理记录](../completed/Evaluation-Datasets.md)。

最终测试发现清单退出 0，2116 个测试标识与迁移前完全一致。

后续目录规则见 [实验数据职责整理](Experiment-Data-Ownership.md)：原始运行数据现归任务 Results，docs 仅保留文档及附件。以上迁移记录描述当时状态。
