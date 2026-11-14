# 语音打断后重新聆听验证

日期：2026-11-05。对应[修复计划](../requirements/Listening-Interruption-Recovery-Plan.md)。

## 故障与边界

用户报告 Assistant 播放语音时长按关闭，再长按开启只响提示音，不录音、不显示光效，首页停留“稍等片刻”且灵动岛持续 loading。源码中新会话能打开感知捕获但因 paused 跳过原生麦克风，随后仍播放启动反馈，与该现象一致。

实际定位的竞态位于 Agents/Support/OutputGateway：cancelCalls 设置 producer 取消围栏并加入真实播放清理；此时到达的 ReplyActivity 空闲快照被视为新执行而取消，已经进入直接投递的同类事实也可能被取消。生产者已发布终态但接收者保留旧占用，后续显式启听仍 paused。

修复只让类型化 ReplyActivity 穿过执行取消围栏并保留在途投递；不改变网关关闭、角色/会话鉴权、消息权限、接收者 revision/incarnation 和用户关闭许可，不跳过播放停止或重新发起模型工作。

## 自动化证据

使用真实 Assistant/SpeechPerception 注册、生产者绑定、OutputGateway、InputGateway、ChannelScheduler 与聆听策略；播放清理为可控替身，模型未推理。

- 旧实现：`interruptedReplyPublishesIdleDuringPlaybackCleanupAndListeningCanRestart` 实际运行失败，6 个断言失败：取消期间空闲事实未释放 paused，随后连续五次显式启听均仍 paused。退出码 1；不是超时或编译失败。原始本机日志 `/tmp/mobileharness-listening-recovery-before.log`。
- 首轮修复：同一测试通过，退出码 0；本机日志 `/tmp/mobileharness-listening-recovery-after.log`。
- 扩展用例同时覆盖取消开始前已进入投递、清理过程中才提交的空闲事实；核对普通播放及合成请求依旧取消、旧 revision 无法恢复占用、关闭许可保持关闭以及五次重开感知捕获。

初次本地定向构建使用 Command Line Tools，因缺少 Metal 编译器失败；后续明确使用已安装完整 Xcode。测试源码初次编译的参数顺序和跨目标 path 类型问题已修正，不将这些尝试计为运行通过。

## 最终检查

- 定向回归：5 个测试（其中两个参数化测试各有 2 个分支）全部通过，退出码 0；包含新增打断恢复、显式关闭、多个回复来源占用合并及实际 Gateway 执行取消。日志 `/tmp/mobileharness-listening-recovery-focused.log`。
- `./scripts/check.sh`：退出码 0。模块边界检查、6 项 Python 测试、严格 Swift 格式检查、全部 Swift 测试及项目/plist 检查通过。其中通用 IntegrationTests 为 1024 项，独立运行时阶段为 225 项（206.653 秒）；其余测试目标同样通过。日志 `/tmp/mobileharness-listening-recovery-check.log`。
- `./scripts/build-ios.sh`：退出码 0。MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个模拟器构建均成功；应用内 Agent/Skill 与原生 Live Activity 资源校验通过。日志 `/tmp/mobileharness-listening-recovery-ios.log`。
- `git diff --check` 和新增计划/验证记录的本地链接检查通过。

以上在现有工作区上完成，保留原有未提交改动。构建中的既有警告不作为失败，也不作为真实设备验收证据。

## 真机待验

未执行真实模型、iPhone 麦克风、原生光效与灵动岛验收，未安装到用户设备。

1. 播放 Assistant 回复期间长按关闭，立即再开，以及等待停止后再开；每种至少五次。
2. 确认关闭后没有录音，开启后出现光效和实际录音，新语音可以进入下一轮回复。
3. 确认首页退出“稍等片刻”，灵动岛不残留已取消回复的 loading。
4. 分别覆盖多句回复、多个角色仍有合法占用、蓝牙/耳机路由及系统音频中断；记录设备/iOS/路由与模型版本。

自动化通过与模拟器构建不能代替以上设备验收。临时日志路径不作为持久附件，本报告保存运行结论与证据范围。

## 2026-11-05 Agent 自有字幕与人声起点

SpeechPerception确认新VAD轮次后、首段ASR前显式开启自己的空字幕；Assistant消费既有speaking控制事件，经内部Display Action clearReply清自己的槽，不请求LLM、不占正式FIFO。各自正常结束及停止／恢复聆听保留文本。根失效显式清理，不依赖麦克风布尔状态间接清理。

Actions分离字幕槽与围栏：clearReply带可选replyInputID冻结旧请求，旧请求续轮不能复活字幕；迟到清理不能删除已经建立的新请求，较早排队输入仍可用新请求身份回复。移除UI回复结束清理、350ms到期淡出和识别换轮时清双方字幕。ASR失败封口保留已有文字；ModelKit及数据库结构未修改。

定向日志 /tmp/caption-ownership-focus-pass.log：ASR首段前空字幕、最终文本唯一递交、开口清理只发Assistant Action且模型供应器不得被调用、重复事件单次清理、独立槽、旧续轮／迟到清理、完成后保留通过。首次测试宏不能直接断言mutating成员，改用捕获局部的辅助函数；旧ASR夹具断言“不发送空字幕”已改为新声起点先发送空字幕。首轮完整检查原生阶段因机械臂测试夹具未注册新增内部Action产生11项missingHandler，补齐对应夹具；随后完整检查主集成1024项、独立原生225项通过（/tmp/caption-ownership-check-final.log）。最后补充停止聆听保留、UI槽清理API语义命名及根失效用例，最终完整检查结果在下文续记。

以上均为本机自动化／替身识别与模型断言，不是新的真实ASR、真实模型或真机交互验收。本轮未安装真机，设备仍为前次2026110501版本。最终iOS构建和未执行范围分别记录。

最终完整检查 ./scripts/check.sh 退出0（/tmp/caption-ownership-check-complete.log）：1024项主集成、225项独立原生测试以及其余包测试、Python／模块边界／Swift格式／plist检查通过；停止／恢复聆听保留两个槽、根失效清理用例通过。当前源码随后完成 ./scripts/build-ios.sh 四目标构建，退出0（/tmp/caption-ownership-ios.log），应用Agent/Skill与Live Activity资源校验通过。git diff --check通过。未运行新的真实模型／ASR或安装真机；不将构建、替身语音流和本机原生测试视为真机语音体验验收。

## 2026-11-14 结束聆听清空双方字幕

- ConversationState 在聆听关闭时重置双方字幕、定稿、等待和回复透明度；重新开启不恢复旧文本。同步 UI 技术说明及 UI/AppWorkflow 的开关断言。
- `./scripts/build-ios.sh`：退出码 0，四个构建目标均 BUILD SUCCEEDED（模拟器构建，不代表真机验收）。
- `./scripts/check.sh`：边界检查、7 项 Python 测试、格式检查及 Swift 编译通过。初轮字幕开关新回归通过；两项 HomeEffects 旧保留断言失败后已按新需求修订。另有 InputDecision 两项、NexArm 跟踪一项、Web 注入声明一项失败。AppWorkflow 测试子进程约两分钟没有新输出后终止，完整检查不可视为通过。
- 尚未进行真机长按／视觉验收。
- 后续原生阶段 228 项测试通过，plist 检查通过；check.sh 最终退出码 1。修订后通过完整 Xcode 的 `swift test --filter 'listeningToggleClearsBothCaptionsAndReopensEmpty|replyEndRetainsCaptionsUntilTheirOwnerClearsOrSessionCloses|noticeVisibilityRestoresRetainedBottomCaptionsAndSleepClearsBoth'`，三项定向回归全部通过（退出码 0）。`git diff --check` 通过。
