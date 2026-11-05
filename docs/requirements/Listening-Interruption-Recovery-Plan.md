# 语音打断后的聆听恢复

日期：2026-11-05。

## 问题与目标

用户在 Assistant 语音输出时长按关闭聆听，再长按开启，出现提示音正常但没有光效/录音、首页“稍等片刻”和灵动岛持续 loading；重复开关不能恢复。

取消执行期间，OutputGateway 的 cancellingProducers 会拒绝同一角色/会话的 ReplyActivity；cancelCalls 也会取消已经进入直接执行的该类通知。生产者已经发布空闲快照，接收者却保留占用，导致后续启听策略仍 paused。修复须保留真实执行清理屏障，不伪造空闲、不清空其他角色占用、不通过重启应用恢复。

## 变更范围与实施顺序

1. `Tests/IntegrationTests/VoiceTests.swift`：在真实 Agent/OutputGateway/InputGateway/SpeechPerception 链路中，用受控播放清理 gate 固定“取消尚未完成时到达空闲通知”的时序；先复现失败，再验证取消期间普通执行仍被拒绝，用户关闭保持关闭，重新开启不再 paused，旧占用通知不能覆盖新 revision，重复启停可恢复。
2. `MobileHarness/Agents/Support/OutputGateway.swift`：把类型化 ReplyActivity 作为独立于回复执行取消的生命周期事实；允许其穿过 producer/scope 取消围栏，并在 cancelCalls 加入执行时保留其在途投递。注册身份、会话、通信权限、接收者 revision/incarnation 校验与关闭生命周期不放宽；不扩大普通 Action/Tool 或任意通信权限。
3. 文档同步：更新 `MobileHarness/Agents/Support/README.md` 的取消与事实投递契约，`MobileHarness/Agents/README.md` 的模块生命周期边界，以及 `MobileHarness/README.md` 的回复取消流程；更新 `Tests/IntegrationTests/README.md` 覆盖说明。
4. 执行定向回归、`./scripts/check.sh`、完整 Xcode 可用时的 `./scripts/build-ios.sh`，结果写入 `docs/validation/Listening-Interruption-Recovery.md`。不新增目录、不改动签名、不覆盖无关工作区改动。

## 验收

- 自动化：固定时序复现旧代码失败，修复后通过；覆盖在途事实投递、取消期间新事实、普通执行取消和较旧 revision 拒绝。
- 真机待验：真实 Assistant 语音输出中长按关闭/再开，至少五次；确认录音、光效和后续识别恢复，灵动岛与首页等待状态退出；覆盖立即重开和等待播放清理后重开。自动化替身和模拟器构建不代替真机验收。

## 实施结果

代码、两种取消/投递时序的回归、所属技术文档与总体流程说明已完成；旧实现稳定复现失败，修复后定向及全量检查、四个 iOS 模拟器构建通过。原范围中的真机复验尚未执行，因此本计划保留在 requirements。证据及限制见[验证记录](../validation/Listening-Interruption-Recovery.md)。

## 2026-11-05 字幕按新的人声轮次由 Agent 收尾

按用户确认实施：新一轮VAD确认人声起点才切换字幕，开启麦克风／恢复聆听／ASR或回复结束均不清除上一轮字幕。SpeechPerception在新识别轮次建立后、首段ASR到达前，显式调用setTranscript空文本开启自己的字幕；复用已有speech.phase(speaking)作为发给Assistant的新输入开始控制事件，重复同轮不重新清理。最终文本仍通过speech.final进入正式FIFO；开始事件不请求LLM。

Assistant独立接纳开始事件并经Gateway调用新增内部Display Action UI.Caption.clearReply，不伪装回复开始、不加入正在执行的模型round。按会话／可信发送者incarnation／turn做单调去重，最多32个会话标记，关闭会话释放；满载明确拒绝，不自动覆盖会话。clearReply只操作本来源回复字幕，使用来源序号、识别轮次和已退休的当前回复输入身份拒绝迟到内容及旧请求续轮；新输入对应的新回复、队列中较早委托输入的新回复仍可建立独立身份。现有语音开口打断路径保持。

Actions的ConversationPresentation不再因识别轮次变化清空双方字幕；仅校验会话、轮次和序号。转写更新只更新自己的槽并解除该槽定稿标记，Assistant显式clearReply只清自己的槽并退休旧回复身份。UI HomeEffects删除回复结束时清除转写和350ms回复淡出清理，不按业务阶段决定清理。根失效／会话关闭保留通用整体清理。失败识别仍封口并恢复许可，不再主动抹掉本轮已有转写。

涉及SpeechPerception、Assistant共享Chat执行、Actions/UI/Conversation与相关端口／装配／注册、UI/Conversation及测试README；均使用现有目录，不改通信协议、Gateway调度设计、ModelKit或数据库结构。实现后同步各拥有者及整体技术文档。覆盖新声起点先于ASR、同轮重复／旧代乱序、各槽独立、终态后保留、旧回复无法复活、旧输入新回复仍可呈现、无开始事件LLM请求、取消／根失效，并执行check.sh和build-ios.sh；真实模型／真机验收单独记录。

并发细化：clearReply可附带Assistant代码保存的replyInputID，冻结“开口时要退休的回复请求”，不由模型指定。这样即使旧请求在清理前后续轮，仍不能重新打开字幕；而之后真正开始的新请求不会被迟到的清理误删。UI按来源保留当前退休请求和清理序号（来源最多32个，沿用既有生产者账本），不按识别turn大小禁止旧委托输入发起的新回复。

收尾审计补充：isVoiceActive=false目前也隐式resetCaptions，会使关闭／重建麦克风绕过Agent字幕政策。该联动一并移除，停止聆听只撤下等待指示并改变呈现门，字幕继续保留。UIHome.invalidate显式调用resetCaptions作为真实根生命周期清理；显式会话重置端口仍可整体清理。相应睡眠／根失效回归同步调整。

本节实现及技术README已同步：双字幕由各自Agent在新人声起点显式切换，移除UI轮次／回复到期／聆听开关的交叉清理，保留根生命周期清理。完整自动化与四目标iOS构建通过；夹具修订、证据和未执行的真机验收见 [验证记录](../validation/Listening-Interruption-Recovery.md#2026-11-05-agent-自有字幕与人声起点)。
