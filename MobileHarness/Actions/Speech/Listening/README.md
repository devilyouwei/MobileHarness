# Speech/Listening — 业务能力与执行

## 职责与关系

实际感知注册与模型图属于注入的上游角色；本目录拥有权限、捕获启停、半双工、启动反馈及真实播放屏障。原始 PCM 由感知角色直接订阅。关闭停止并加入原生采集和播放清理，再释放共享音频；回复执行的取消边界见下文。页面离开不释放根会话。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [ListeningActions.swift](ListeningActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [ListeningActivationFeedback.swift](ListeningActivationFeedback.swift) | 聆听启动反馈的真实结果组合 |
| [VoiceNativeEffects.swift](VoiceNativeEffects.swift) | 语音会话的提示音、触觉与播放执行 |
| [VoiceOutputHandling.swift](../../Support/Contracts/VoiceOutputHandling.swift) | 原生语音端点接口，复用独立 UI 呈现端口 |
| [VoiceSessionConnections.swift](VoiceSessionConnections.swift) | 上游感知生命周期与公开执行依赖 |
| [VoiceSessionCoordinator.swift](VoiceSessionCoordinator.swift) | 权限、采集、半双工播放屏障与根会话清理 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)

VoiceSessionCoordinator.start 在发布 isReady 前完成 wake/0.85 音效 PCM 缓存准备与触觉准备，失败传播并 shutdown；不播放、不申请录音权限、不打开采集。根启动调用拥有异步准备，页面和手势不拥有准备任务。移除按压预热任务及取消状态；prepareListening 兼容端口仅复用缓存，不再拥有任务。实际长按启动后沿用原播放、光效与采集流程。

## Execution ownership and lifecycle

VoiceSessionCoordinator is retained and cleaned by ActionsContainer. Voice output/presentation/perception protocols and typed values live in FunctionContracts. Business checks use current session/generation/native conditions, without role-name permission tests. Agent cancellation policy arrives through the injected narrow host interface.

## BasicSkill 启停与关闭完成

startListening / stopListening 由 @Action 声明并在 SpeechModule 显式绑定；参数校验位于能力调用前，可用于纯 preflight。VoiceSessionCoordinator.setListening 验证根会话、已启动与设置状态，经 VoicePerceptionHandling.setListening 取得权威 enabled/paused/revision，复用内部策略应用。revision 拒绝迟到快照；启动保留权限、反馈、清理加入及半双工屏障。

stopListening 先撤销感知许可，再同步停止原生播放、失效采集代并屏蔽麦克风，返回前加入 cleanupTask（含既有清理、采集关闭与感知 closeCapture）。Action 关闭分支不调用 cancelReply，避免当前执行取消并等待自己；它不隐式关闭业务 Task。UI 手势关闭与生命周期停机仍取消回复；系统音频中断只退役采集，保留回复。取消不会恢复已撤销许可；后续回复活动和播放清理只能在许可有效时恢复采集。下一次启用由长按或用户明确要求的 startListening 发起。

明确关闭在未启动或已关闭时同样归一为“语音已停止”；内部策略停机保留已有失败诊断状态。

## Recording hold

beginVideoAudio retains the existing voice generation, blocks listening start/resume and new speech/cue playback, joins microphone.setEnabled(false), then joins full AudioInputOutput.stop and checks cleanupFailure before allowing native recording. Stopping input samples alone does not release the shared native voice owner. The handoff does not cancel the current reply, so a voice-originated recording Action cannot wait for itself. A cancelled pause still joins native cleanup; cleanup failure prevents recording admission. It does not erase user listening intent. endVideoAudio releases the hold and resumes only if the caller remains foreground, the same non-nil generation is current, readiness remains valid, settings are unchanged and reply/playback barriers allow it. User-off, shutdown or background cannot be undone by a late recording completion. A voice owner bound during an existing recording inherits a hold without inventing earlier listening intent. Full stop closes the old native event subscription; actual listening resume binds a new subscription after microphone admission. Cancelled event observers cannot stop the resumed generation. Native microphone ownership is independently enforced by PlatformKit.

全双工能力来自已确认启用的回声消除输入。受限路线在实际播放取得准入时暂停识别，末次播放结束或取消加入清理后恢复。恢复校验用户许可、语音代际、录像和播放屏障。感知结束语音识别后自行接纳下一轮。

正常播放完成及恢复聆听保留转写和回复字幕。SpeechPerception 开启下一识别轮次时更新转写槽，回复所有者通过 beginReplyTurn 更新回复槽。ConversationPresentationController 分别校验会话和对应身份。原生音频打断、采集和 UI 字幕各自完成清理。

SpeechListening日志记录策略收到/应用的revision和enabled/paused、播放计数、采集代是否存在、
恢复调用/返回/提交及取消边界。只有状态与计数公开；既有内容日志仍保持private。日志不改变
采集许可、播放屏障或恢复策略，也不把调用开始当作实际恢复成功。

## 播放事实与展示归属

VoiceNativeEffects在首个有效PCM和播放drain/失败清理边界加入activeChanged回调；VoiceSessionCoordinator将audioID和active沿VoiceSessionConnections传回Assistant的语音子能力。回调不依赖页面和UI状态观察，不改变原始播放错误。频谱worker仍由播放器持有、取消并加入，通过专用UI端口更新平滑数值及清零；不逐帧提交Island Action。聆听激活的音效/震动仍与采集接纳共同完成，展示角色不能绕过原生资源与清理。

提示音参数使用共享 UIFeedbackTypes.Cue 的六项封闭枚举，算法和长度由 [UI/Feedback](../../UI/Feedback/README.md) 定义。

## 采集故障隔离与受限恢复

普通 Action 的失败由执行结果回传上游，不调用 stopVoice。原生 PCM 终止、音频事件失败和媒体服务重置由 captureFault 退役损坏的音频，不取消 Assistant 回复、不发布 listening stop/captureEnded，也不撤销用户的聆听意图。麦克风不可用立即清除 isVoiceActive/动画并显示实际故障。

VoiceCaptureRecovery 拥有单 worker 和一个合并的最新故障槽；重复事件合并，任一明确不允许重启的事件保留该限制。同一次明确开启最多自动重建一次：先取消并加入事件消费、麦克风、播放及完整原生停止，检查 cleanupFailure，再 openCapture 并经过现有回复/录像屏障恢复。原生恢复等待上限 10 秒，取消后仍加入原生清理；首帧接纳前不显示已恢复。新故障或恢复失败只退役并显示不可用，不能无限重试或自动重放拍照/保存等操作。系统 interruption/routeChanged 不自动重启；PCM interrupted 同样禁止恢复，后续 reset 不能在同一会话解除该限制。

恢复等待实际播放或录像释放音频资源，并检查恢复状态。用户明确调用 startListening 可以重新建立恢复预算，关闭再开启也可建立新会话。用户关闭、设置切换和 shutdown 同步撤销恢复并等待 worker 退出。根会话拥有恢复生命周期。

对话请求 preferSpatial=false；startInput 使用捕获代的实际 supportsFullDuplex，页面状态区分系统回声消除、语音回声消除和受限模式；不能只依据配置偏好宣称全双工。原生和端点延迟仍独立于 Decision，不以 UI 状态推定回声消除质量。
