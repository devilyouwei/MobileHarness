# 原生音视频故障诊断与错误保真

## 现场与证据边界

2026-11-06 用户截图：同一会话在 13:32 上报 `platform.audio.spatial nativeEvent invalidFormat` 和 `platform.vision.camera nativeEvent AVFoundationErrorDomain -11819`。本地 Apple SDK 将 -11819 定义为 `AVErrorMediaServicesWereReset`。故障版本的空间音频把运行错误和中断都替换成 invalidFormat，因此不能据截图认定 PCM 格式错误，也不能确认两个事件的因果顺序。

2026-11-06 调查时手机未连接，尚未取得系统崩溃日志或复现记录。媒体服务重置触发原因及真实设备复验属于本次未完成调查，不能以代码检查代替。

## 实施范围（先于代码）

- `PlatformKit/Audio/SpatialAudioCapture.swift`：原生运行通知保留 NSError（domain/code/userInfo）；缺失原生错误使用明确 runtimeFailed；原生中断使用 interrupted。启动未运行使用 startFailed 或 interrupted，并优先保留已收到的原生失败。停止先关闭本代通知接纳，再停止并加入原生回调，避免清理产生迟到故障。
- 同文件的通知桥独立于 FOA 硬件后端，在 macOS/iOS 均编译，以实际 NotificationCenter 通知测试错误传播；测试不得请求权限或打开设备。首个失败同时传给 readiness、PCM source 和 Platform 报告，重复事件不覆写主因。
- `PlatformKit/Audio/MicrophoneFrame.swift`：补充 runtimeFailed/startFailed 原生错误分类，不改变已有 PCM 验证。
- `Actions/Speech/Detection/AudioDetectionExecution.swift` 及本目录 README：穷举映射兼容新增错误，直接传播原生启动/运行失败，不将其映射成格式错误；不改变检测生命周期。
- `Tests/IntegrationTests/AudioCaptureReadinessTests.swift`：覆盖原生错误、无 payload、中断、启动前/后失败、重复/迟到事件及无关 session 隔离。
- 更新 Audio README 和测试 README，验证记录放 `docs/validation/`。不改变模块边界、Gateway、Writer、媒体采集策略，不推测性关闭 FOA 或自动重拍。

## 验证与后续

错误保真、启动错误分类、停止通知围栏及定向回归已实现；完整 `scripts/check.sh`（含原生运行时阶段）与四个 iOS 构建通过。媒体服务重置根因、设备日志和真机复验未完成，本调查保留在 requirements。证据见 [验证记录](../../validation/Native-Media-Failure-Diagnosis.md)。

用户补充聊天记录：13:31 ignorePhoto(media_9)→takePhoto；13:32 用户要求保存，生成 savePhoto(media_10)，消费其执行观察后又生成 closeCamera，消费 closeCamera 执行观察的下一轮 cancelled。保存和关闭所在轮均显示 completed；截图未展开 Action 执行观察，不能以轮状态替代保存/关闭原生结果。保存链路本身不停止相机；关闭在相机与视觉两个分支均无需求时才释放共享采集并加入原生停止。下一步需对照相机关闭、并行空间音频和媒体重置的细粒度时间线。

VoiceSessionCoordinator 的实际错误路径为 PCM/音频事件失败→stopVoice→requestReplyCancellation；所以末轮 cancelled 与媒体故障导致回复取消的解释相容，尚不能从分钟级截图认定因果或取消来源。当前不凭该截图修改采集策略或压制相机错误。

实施后运行定向测试、`scripts/check.sh`、`scripts/build-ios.sh`。待连接设备后读取故障时段媒体服务日志、确认触发操作，依据新证据决定是否需要媒体对象恢复修复；记录真机安装与复验结果。

Apple 恢复建议：[QA1749](https://developer.apple.com/library/archive/qa/qa1749/_index.html)。重置后的对象重建与再次激活需要结合当前所有者和用户意图设计，不能无条件重试有副作用的拍照/录像。

## 2026-11-10 后续证据与拟议修复

已取得 14:51:04 cameracaptured 系统崩溃报告和同段手机请求记录：拍照成功；网页请求先生成 closeCamera；关闭成功观察后系统停止采集图超时崩溃，下一轮被取消，尚无 Web 浏览 Action。具体时间线、因果边界和修复次序见[现场分析](../../validation/Native-Media-Failure-Diagnosis.md#2026-11-10-1451-真机关闭相机故障)。

拟议工作：明确窗口新增不隐含关闭相机的教学与回归；为 PlatformKit Audio/Vision 增加 lost/reset 的失效代清理、错误保持与原生对象重建；由 Actions 保持用户许可及显式恢复，绝不自动重放拍照/保存；进行 mono/FOA 与相机停止组合的真机对照，定位底层超时触发条件。需要覆盖 stop/failed 竞态、重复/迟到重置、取消期间恢复、首帧验证失败和无业务副作用重放。

本轮未实施上述恢复修复，未完成真机触发复现。原错误保真修复已在现场显示两条真实 -11819；诊断改善不等于媒体服务问题已解决。

## 2026-11-10 修复实施计划：执行失败与聆听隔离

用户授权修复：Action 的可报告失败进入原有结果观察/ReACT，不关闭聆听或取消整个回复；打开新窗口不隐式关闭已有窗口。

- 保留 AgentChatWorker/Gateway 已有显式模型调用失败观察与回合屏障，增加回归证明 thrown Action、失败报告均能续推且下一输入仍可执行；取消、反馈投递失败不伪装成可重试业务错误。
- Actions/Speech/Listening/VoiceSessionCoordinator 分离采集故障与用户停止。采集故障保留回复、聆听意图与会话身份，真实停止损坏的采集；每次用户开启的聆听会话至多一次自动重建。重建先加入旧采集/播放/原生清理，再重新 openCapture，只有首 PCM 到达才显示恢复；回复/录像屏障期间延后接纳采集。重建失败或第二次故障显示不可用，等待用户重新启用，不循环重试、不 replay 拍照/保存。用户关闭、设置切换、根关闭取消并加入恢复，旧任务不能重新打开麦克风。
- PlatformKit/Audio 的原生完整 stop 释放采集/播放引擎及连接，使下一次启动使用新图；媒体服务重置作为独立原生事件终止失效流/播放等待，保留原生错误。平台仅报告事实，是否恢复由 Actions 决定。
- 原生 interruption/route-change 仍停止实际音频；不把音频故障变成用户主动 cancelReply。保留明确用户停止的回复取消语义。
- Assistant 常驻 Instructions 及 Photography/ApplicationControl/WebBrowsing 教学说明多窗口独立管理。无明确关闭/丢弃要求，不因新目标、浏览网页或 Task 切换关闭旧窗口；删除 Photography 隐式 Task 收尾关闭规则，保存后也保留窗口。关闭破坏临时媒体的语义不变。
- 同步 Actions/Listening、PlatformKit/Audio、Resources/Agents/Skills、总体流程及测试 README 的实施契约。以现有文件承载测试，不建目录。
- 验证：采集恢复失败/重试预算/取消加入测试，Action failure→observation→下一轮/下一输入测试，提示词契约测试；完整 check.sh 与四 scheme build-ios.sh。媒体服务真实重置与 FOA/mono/camera 对照仍需物理设备验收，不将自动化替身结果视为修复系统 daemon 超时。

实施细化：自动重建首帧等待上限为 10 秒，超时取消并加入真实清理，不能报告恢复成功；受系统 interruption/路由切换影响时仅退役采集，不自动申请恢复。重复故障合并成一个最新待处理故障；恢复进行中用户关闭优先。内部字幕/语音失败继续留在执行记录，不单独触发模型自激循环；同轮存在模型显式调用的业务观察时，内部输出失败不能阻断该观察的 ReACT。

共享原生事件新增 reset 后，Speech/Detection 的事件消费也需识别该分支：记为运行故障而非路由变化，原生 NSError 留在 Platform 报告/PCM 失败证据中。其业务不自动重启检测。

恢复围栏细化：PCM 源携带的 interrupted 与原生事件 interruption 一致地禁止自动重启；一旦观察到不允许恢复的中断，同一会话后续 reset 也不能自动解除，必须重新明确启用。该限制优先于同时到达的可恢复故障。

取消/占用复核：恢复拆为退役、重建感知绑定、解除恢复 gate 后恢复采集三个阶段，防止回复/录像刚结束的恢复通知被 gate 吞掉。10 秒超时和用户关闭同步 invalidate 正在启动的 ListeningCaptureWorkflow，再加入子任务；仅取消等待任务不足以打断其独立 native start worker。

本轮代码与教学修复已经实施；验证与既有整批跟踪测试失败记录见 validation 同名文档。系统摄像服务超时的具体触发节点仍未确证，FOA/mono/camera 对照及真实媒体服务重置后的复测保留为后续真机验收，不将本轮恢复逻辑当作修复 iOS daemon 的证明。

## 提示词职责收敛：通用教学

用户要求新增教学解耦，不以故障现场或特定业务组合编写模型指令。

修改前约定：将独立窗口与 Task/Skill 生命周期、显式关闭意图的通用原则仅放在常驻 BasicSkill 的 Lifetime and completion；Assistant Instructions 恢复身份/交互职责，不重复窗口教学或既有失败规则。Photography 删除“拍照后打开百度”的场景、Web 调用和重复通用窗口原则，仅保留自身媒体处置与关闭回执语义；ApplicationControl/WebBrowsing 删除 Camera 示例和重复通用规则，各自既有窗口 ID/导航/关闭操作说明继续归所属 Skill。修改四个 Skill 的 revision；同步资源/Assistant README 和已有提示词组合断言。验证模板组合、资源声明与打包；不改运行时恢复代码，不把提示词契约测试当作真实模型遵从证明。
