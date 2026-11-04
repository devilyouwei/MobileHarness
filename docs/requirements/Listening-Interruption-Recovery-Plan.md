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
