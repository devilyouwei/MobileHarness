# BasicSkill 聆听控制 Actions

## 范围与行为

本次只实现两个无参数函数 `Speech.Listening.startListening` / `stopListening`，通过 BasicSkill 常驻别名提供自然语言打开、结束聆听。结束对话等明确退出语音意图调用 stopListening；关闭后回复结束、播放清理、页面切换均不能重新授权采集，下一次由用户长按或明确要求打开。此操作不隐式结束或取消业务 Task。窗口化相机、录像、灵动岛留待后续设计，本次不改动。

## 实施设计（代码修改前）

- `Actions/Speech/Listening/ListeningActions.swift`：沿用 @Action、纯参数校验、注入能力与 void 完成风格；拒绝所有参数，完成表示实际执行已加入。
- `Actions/Speech/Support/SpeechCapabilities.swift`、`SpeechModule.swift`：显式聆听控制端口及两个函数绑定，未提供能力时明确失败；不复用可伪造 enabled/paused/revision 的内部 update 给模型。
- `Actions/Support/Contracts/{VoiceOutputHandling,VoicePerceptionHandling,SpeechTypes}.swift`：中立控制端口及带单调 revision 的聆听策略值，不传递 Agent 实现。
- `Agents/SpeechPerception/SpeechPerceptionAgent.swift`：原有 owner 负责启停许可，拒绝错误会话、停机及暂停期间启用。直接控制返回策略快照，不再次排队执行 Action，避免同 Channel 等待和重复执行。关闭推进 admission epoch，清空 pendingFinal；回复活动只影响 paused，不能重置 enabled。
- `Actions/Speech/SpeechExecutionEndpoint.swift`、`Listening/VoiceSessionCoordinator.swift`：校验会话并将策略实际应用；关闭立即屏蔽采集、停止原生音频并加入 cleanup。Action 自身关闭不调用会等待当前 Action 的 cancelReply，避免自取消/自等待；手势、系统中断等原路径仍取消回复。现有 revision 防线拒绝迟到策略。启用保留权限、唤醒反馈和回复播放屏障。
- `Resources/Skills/BasicSkill/{Skill.json,Instructions.md}`：revision 递增，增加两个别名，独立 ListeningControl Channel；退出意图只输出关闭 Action，不在其后说话或自动重开。
- 实现后更新 Actions、Speech、Listening、Support、Contracts、Agents/SpeechPerception、Resources/Skills 的技术 README 及总体跨模块设计。

## 验证计划

覆盖无参数校验、失败与取消传播、缺失能力、BasicSkill 目录、启停幂等、错误会话/非运行态、关闭后迟到回复不能重开以及手势重新启用。运行 scripts/check.sh 和可用的 scripts/build-ios.sh；真实模型理解退出意图、麦克风停机和长按恢复须单列真机验收，自动测试不代替该证据。

## 实施结果

两个入口、权威策略端口、原生执行复用及 BasicSkill 已接入。新增回归覆盖参数、缺失能力、会话、状态、失败/取消与重新启用。验证记录见 [Listening Actions](../validation/Listening-Actions.md)；真实模型及真机验收独立跟进。

明确关闭即使在未启动或已关闭时，也将展示归一为“语音已停止”；内部失败/采集结束策略继续保留原始诊断状态。

原定代码、文档及自动验证范围已完成。真实模型与真机聆听验收作为独立事项在 [路线图](../Roadmap.md#acceptance-work) 及验证记录跟进。
