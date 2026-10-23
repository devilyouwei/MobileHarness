# PlatformKit 容器与 Gateway 设备接入验证

日期：2026-10-17。基线 a460d99c；未自动提交本轮实施。已签名构建、安装并启动于配对的 iPhone 17 Pro。

## 实现范围

实例级 Platform 根及三个子能力；AppLifecycle 根管理；Gateway 原生媒体/技术事件适配；只读 Tool 附件与最新态传输；UI 独立影像/姿态更新与共享 Metal 合成、750 ms 分别过期。基础库无项目依赖，未新增目录或编译目标。

## 自动化与构建

| 检查 | 结果与边界 |
| --- | --- |
| 静态边界、源码唯一归属、README、FactoryKit 隔离 | ✅ check-modelkit-boundaries.py 通过；未新增目录、目标或第三方依赖。 |
| 格式与 Python 回归 | ✅ check.sh 的严格 Swift 格式检查与六项模型下载脚本测试通过。 |
| 专项及相关回归 | ✅ 最终定向运行 UI 3 项、Integration 38 项通过；包含新增根隔离/失败、订阅与溢出、媒体通道、附件、清屏，以及声音/视觉和蓝牙恢复回归。 |
| 完整 check.sh | ❌ 最后一次运行 IntegrationTests 共 921 项，10 项失败、22 个问题；其他目标完成。失败涉及 atomicStableOffTarget、七项 soundSource、visionStatistics 和 visionResolvesOpaque；这些用例在定向运行中通过。此前一次全量还出现 publicationOverflow 的失败，定向运行通过。并行全量结果仍未通过，不宣称已证明是既有问题。 |
| iOS 设备目标 | ✅ 未签名通用设备构建通过；随后使用现有本地签名配置完成 MobileHarness / Debug 真机构建，并由 devicectl 成功安装、启动 dev.mobileharness.app 于 iPhone 17 Pro。日志：/tmp/mobileharness-platform-device-install-build.log、/tmp/mobileharness-platform-device-install.log、/tmp/mobileharness-platform-device-launch.log。 |
| Simulator 构建脚本 | ❌ scripts/build-ios.sh 在 MobileHarnessSimulator 被 coreai-models 的 CoreAIShared 缺少 CoreAI 阻断，后续 scheme 未执行。 |
| Metal shader | ✅ 使用主机 Metal 设备编译相机与骨架两条真实管线通过；不等同 iOS 上屏、图像方向或延迟验收。 |
| 差异检查 | ✅ git diff --check；项目元数据另行 plutil 校验。 |

第一次完整运行也存在并行感知超时；定向运行用于区分测试运行条件，不能替代全量通过。所有本轮改动保持未提交。

## 独立验收

❌ 未执行真实模型、麦克风/FOA、相机/Photos、Metal 上屏帧率/延迟/内存、前后台与物理 BLE/USB 验收。编译和替身测试不证明原生效果或物理停机。

## 相机与姿态独立输出修复

✅ CameraCoordinator 在受生命周期管理的任务中独立订阅容量为一的最新原生帧，直接提交 UI 自有图像值；YOLO 继续通过 Gateway 与 Pose Tool 更新骨架。模型启动、失败、空检测和超时不清除实时影像。图像与骨架分别按捕获时间在 750 ms 后失效；停机、换镜头和后台取消并加入两个任务，清除旧会话。骨架使用最新有效结果，沿用相同几何/镜像变换，不再要求与当前预览帧序号相同；仍验证 Tool 自带的原始帧、会话及单调序号。真实进程崩溃不在此故障隔离范围。

### 独立输出修复验证（2026-10-17）

- ✅ 5 项相机专项回归通过：姿态失败保留图像、更新后续帧、姿态独立过期、图像断流过期、错帧/乱序拒绝、关闭清理和渲染故障代际围栏。合成像素测试不代表真机上屏效果。
- ✅ 签名 Debug 真机构建通过，devicectl 安装并启动于 iPhone 17 Pro；日志 /tmp/mobileharness-camera-split-device-build.log、/tmp/mobileharness-camera-split-install.log、/tmp/mobileharness-camera-split-launch.log。
- ✅ 本轮 check.sh 静态边界、严格格式及六项 Python 测试通过；UI 全部 119 项通过，包含本轮五项专项测试。独立 plutil 元数据与 git diff --check 通过。
- ❌ 本轮 check.sh 的 Integration 921 项中 10 项失败、19 个问题，涉及 atomicStableOffTarget、七项 soundSource、visionDiscardsOverBudgetResults 和 visionResolvesOpaque；不宣称全量通过。日志 /tmp/mobileharness-camera-split-check.log。
- ❌ build-ios.sh 在 Simulator 的 CoreAIShared 缺少 CoreAI 依赖处失败；后续 scheme 未运行。日志 /tmp/mobileharness-camera-split-simulator.log。
- ❌ 尚未实际操作验收修复后的摄像头上屏、镜头切换及真实 YOLO 故障恢复；安装与启动不等于功能验收，也未确认用户所述 YOLO 崩溃的底层原因。

✅ 本轮相关定向复跑 18 项通过，包含相机五项及全量失败涉及的声音/视觉/动作超时用例；不替代全量通过。日志 /tmp/mobileharness-camera-split-related.log。

## YOLO 停止与录音 overflow 修复（2026-10-17）

用户确认背景视频正常而骨架停止/报错；另提供“录音中断：overflow”截图。代码审计确认容器化后主录音新增 MainActor 转发和第二级 64 包订阅队列，截图的通用错误路径与 NativeSubscriptionError.overflow 相符；未采集故障现场的调度轨迹，不将其表述为唯一根因。

✅ 主录音恢复为原生 64 包 FIFO 直接交付；原生回调通过 NativeInputSession 单代围栏向可选观察者广播，不经过主线程转发/第二级主队列。旧代关闭后迟到包失效，慢观察者单独溢出；主录音不扩大缓冲、不丢 PCM。YOLO 运行错误在单 worker 内 250 ms 退避后处理最新帧，连续三次停止，永久契约错误立即停止，终态带有界诊断；Gateway 单独拒绝已过期媒体并继续消费，仍传播新鲜非法附件错误。

- ✅ 首轮 9 项定向测试通过；最终新增测试在完整运行中也均通过，包括派发途中过期及原生失败传播。
- ✅ 最终签名设备构建通过：/tmp/mobileharness-stream-recovery-device-final.log。已安装 iPhone 17 Pro：/tmp/mobileharness-stream-recovery-install.log。
- ❌ 首次启动被设备锁屏拒绝（Locked），不记为启动成功：/tmp/mobileharness-stream-recovery-launch.log。
- ✅ check.sh 的静态边界、严格格式与六项 Python 回归通过；UI 119 项通过；独立 plutil 与 git diff --check 通过。
- ❌ 完整 Integration 929 项，11 项失败、21 个问题：nexArmPlaybackCongestion、atomicStableOffTarget、八项 soundSource、visionResolvesOpaque。不宣称已证明是既有问题。日志 /tmp/mobileharness-stream-recovery-check.log。
- ❌ Simulator 仍被 CoreAIShared 缺少 CoreAI 阻断，后续 scheme 未运行：/tmp/mobileharness-stream-recovery-simulator.log。
- ❌ 未完成真实 YOLO、持续录音和相机同时运行、切换/前后台、温度和内存的独立真机验收。同步原生推理若真正不返回，取消仍需等待，未通过抛弃任务伪造停机成功。

✅ 本轮最终相关定向复跑：Integration 30 项、AppWorkflow 5 项，共 35 项通过，包含录音启停/迟到启动清理、新增八项以及全量失败涉及用例；不替代全量通过。日志 /tmp/mobileharness-stream-recovery-related.log。

✅ 用户解锁后已成功启动修复版 dev.mobileharness.app；此前锁屏拒绝仅为首次启动尝试的历史结果。日志 /tmp/mobileharness-stream-recovery-launch-unlocked.log。仍未完成持续录音与真实 YOLO 的独立操作验收。

## 视觉静默停止与呈现诊断（2026-10-17）

本轮反馈为影像仍正常、骨架消失且无 Agent 异常/toast，未取得原生 YOLO 故障现场堆栈，不将其直接判定为 Core ML 进程崩溃。

✅ 修复源分支先结束就取消输出分支的竞态：输入正常结束/失败先让角色发布带原因的终态，输出排空后才清理。新增 VisionPipelineWorkflow，显式取消不报异常；输出错误取消并加入输入。原生调用仍等待真实完成，未抛弃正在运行的模型。

✅ 根级每秒采样角色健康；3 秒无进展阈值区分输入静默、原生推理未返回、无新鲜结果；Tool 呈现错误及 Gateway 单独丢弃的过期媒体也参与健康诊断。同一连续诊断只上报一次，成功后解除提示。记录序号、处理/过期/模型错误计数和最近原因；记录到 Agent 分类运行异常及短 toast。阈值不代表系统调度时间上限。

✅ 图像接纳移除未使用的上下文 snapshot 读取，避免等待持久化写锁；开始推理仍使用已提交上下文。合成测试在真实仓库 commit 被门闩阻塞时验证新帧接纳能独立完成。

- ✅ 最终 21 项定向回归通过，含本轮新增 11 项；覆盖源结束/失败排空终态、输出失败/取消加入、输入静默/推理阻塞/过期及呈现健康、写锁隔离。另验证真实 VisionPerception 终态经绑定 Gateway consumer、失败快照到 Agent 分类异常与 toast 的完整链路，保留原始错误与会话/输入关联。日志 /tmp/mobileharness-vision-observability-e2e-final.log。
- ✅ 最终签名设备构建成功，已安装并启动于 iPhone 17 Pro。日志 /tmp/mobileharness-vision-observability-device-final2.log、/tmp/mobileharness-vision-observability-install-final.log、/tmp/mobileharness-vision-observability-launch-final.log。
- ✅ 最终 check.sh 的静态边界、严格格式、六项 Python 回归通过；UI 119 项通过。另行 plutil 与 git diff --check 通过。最后追加的端到端测试在定向运行通过，并单独校验格式。
- ❌ 完整 Integration 939 项中 10 项失败、19 个问题：nexArmPlaybackCongestion、atomicStableOffTarget 和八项 soundSource。本轮该次运行没有视觉用例失败，不据此宣称证明了原有失败原因。日志 /tmp/mobileharness-vision-observability-check-final.log。该完整运行先于最后追加的一项端到端测试。
- ❌ 较早一次完整运行发生视觉/声音等失败，Integration 长时间不退出，终止该测试进程后继续验证；不计为完整通过。日志 /tmp/mobileharness-vision-observability-check.log。
- ❌ Simulator 仍因 CoreAIShared 缺少 CoreAI 构建失败，后续 scheme 未执行。日志 /tmp/mobileharness-vision-observability-simulator.log。
- ❌ 尚无修复后持续真机 YOLO 的独立验收；已请求用户复现后提供新增故障码和详情。安装、启动和合成回归不证明原生推理已稳定，也未定位到真实故障的底层原因。

## 视觉订阅状态积压修复（2026-10-17）

用户复现返回 queueFull、pipeline.failed。审计发现角色内部的最新状态替换策略未传递到 Gateway 输出消费端，视线 Tool 与姿态广播进入普通 FIFO；这解释了慢消费下的积压路径，但没有故障现场堆栈，不能断言已排除其他原生模型问题。

✅ VisionPerception 通过显式回调声明骨架、视线和姿态广播的状态替换键；Gateway 按来源、会话和任务作用域隔离键，使用有界最新状态投递。每个状态键只保留最新待处理值，正在处理的调用等待真实完成。媒体沿用独立最新通道；离散 Action、定向消息和生成轮次不允许被该策略替换。Gateway 不识别视觉业务名称。分支错误立即传播并取消、加入其他分支，避免原始错误被随后积压掩盖；容量拒绝附带通道、容量、来源、会话、序号与 full/closed 原因。

- ✅ 15 项专项回归通过，包括新增六项：阻塞视线和姿态消费时连续发送 400 次更新只交付首个与最终状态、离散操作仍能执行、分支原始错误传播、FIFO 溢出详情、禁止替换命令/定向消息/生成轮次、跨会话隔离及状态键容量约束。日志 /tmp/mobileharness-vision-queue-tests-final.log。
- ✅ 相关定向复跑 Integration 67 项通过，另一个目标 1 项通过，覆盖全量运行失败涉及的声音、视觉、媒体与动作时限用例；不替代全量通过。日志 /tmp/mobileharness-vision-queue-related.log。
- ✅ 签名 Debug 真机构建成功，修复版已安装 iPhone 17 Pro。日志 /tmp/mobileharness-vision-queue-device.log、/tmp/mobileharness-vision-queue-install.log。
- ❌ 启动尝试因手机锁屏被系统拒绝，尚未启动验收本轮版本。日志 /tmp/mobileharness-vision-queue-launch.log。
- ✅ check.sh 静态边界、README/源码归属、严格格式与六项 Python 回归通过，UI 119 项通过；另行 plutil 与 git diff --check 通过。
- ❌ 完整 Integration 946 项中 13 项失败、23 个问题：publicationOverflowDoesNotWaitForDiagnosticCallbacks、atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、八项 soundSource、visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers、mediaTransportSurvivesExpiryDuringDispatchAndDisplaysNextFrame、visionStatisticsMeasureCaptureToResultThroughPoseTool。不宣称已证明为既有问题。日志 /tmp/mobileharness-vision-queue-check.log。
- ❌ scripts/build-ios.sh 的 Simulator 构建仍被 CoreAIShared 缺少 CoreAI 阻断，后续 scheme 未执行。日志 /tmp/mobileharness-vision-queue-simulator.log。
- ❌ 尚未完成真实 YOLO 长时间运行及声音/视觉并发的真机验收；合成慢消费测试不代表 Core ML 已稳定。

## 现有 Metal 渲染优化（2026-10-17）

✅ 保留原生像素纹理与单 pass 图像/骨架合成，改为专用线程上的 CAMetalDisplayLink 驱动。UIView 主线程只管理布局、最新展示提交和代际故障通知；不调用 nextDrawable、不创建渲染任务历史。最新状态槽合并更新，最高 60 Hz 消费，无更新时暂停。两个固定 GPU 槽及骨架 buffer 循环复用，姿态与几何不变时复用网格；GPU 完成前不改写所属 buffer，像素与纹理保留至完成。

✅ 无帧停止与同图层重挂载使用真实完成信号交接，主线程不等待 GPU。原生合成验证发现并修复两项清理缺陷：Foundation run(until:) 外层时限延迟线程退出，以及等待 GPU 时借用的信号量许可未归还导致析构陷阱。现使用 CFRunLoopRun/Stop，归还许可后清理；新增长期回归直接执行同一生产渲染器，不复制渲染实现。

- ✅ 最终相机专项 10 项通过：最新状态替换/排空后再接纳/停止、网格缓存与容量/镜像/方向、独立影像与骨架到期/故障，以及 macOS 原生 Metal。后者包含两次无帧停止和十次真实 display-link/GPU 完成，连续停止后新实例可在旧实例尚未清理完时启动并等待图层交接。日志 /tmp/mobileharness-metal-tests-final.log。
- ✅ 最终 scripts/check.sh 的静态边界、源码归属/README、严格格式与六项 Python 回归通过，UITests 78 项全部通过（包括原生 Metal）；独立 plutil 与 git diff --check 通过。日志 /tmp/mobileharness-metal-check-final.log。
- ❌ 最终完整 Integration 946 项中七项声音感知用例失败、14 个问题：soundSourceStopCancelsAndJoinsAnInFlightPublisher、soundSourceMonoIsUnavailableAndRejectedPublicationDoesNotStopRecognition、soundSourceBroadcastCrossesGatewaysWithBoundIdentityAndCaptureDeadline、soundSourceNonSpeechBroadcastDoesNotRequireSubscribersOrOpenASR、soundSourceReplyGateClearsDirectionAndResumeStartsANewWindow、soundSourceOnlyDiagnosticCrossesGatewaysWithoutModelsOrPresentationGrants、soundSourceSlowSubscriberDoesNotBlockFollowingDirections。不宣称全量通过，也不据此断言是既有问题。
- ✅ 最终相关定向复跑 UI 5 项、Integration 16 项通过，包含本轮原生渲染及全量失败涉及用例；不能替代全量通过。日志 /tmp/mobileharness-metal-related-final.log。较早一次相关运行还验证了 66 项视觉/声音/媒体与传输回归，日志 /tmp/mobileharness-metal-related.log。
- ✅ 最终签名 Debug 真机构建通过：/tmp/mobileharness-metal-device-final.log。最终重装首次连接超时，重试后成功安装并启动 iPhone 17 Pro 上的 dev.mobileharness.app：/tmp/mobileharness-metal-install-retry.log、/tmp/mobileharness-metal-launch-retry.log。此前一次启动锁屏拒绝及较早安装不是最终启动结论。
- ❌ scripts/build-ios.sh 仍在 Simulator 的 CoreAIShared 缺少 CoreAI 依赖处失败，后续 scheme 未执行。日志 /tmp/mobileharness-metal-simulator.log。
- ❌ 尚未测量 iPhone 上的实际渲染 FPS、CPU/GPU 时长、功耗/热状态，也未完成真实相机与 YOLO 长时间并发、镜头切换和前后台验收。最高 60 Hz 为调度配置，不是实测上屏帧率；macOS 合成像素和 GPU 成功不代表 iPhone 原生效果或模型稳定性。

初轮专项中的固定 90 ms 到期等待在原生窗口并发初始化时出现调度竞争；已改为观察实际到期状态的有界等待，保留图像独立存活断言。第一次完整检查（原生渲染回归补齐前）Integration 为八项失败、15 个问题，不覆盖最终结果；日志 /tmp/mobileharness-metal-check.log。

## UI 根容器与相机接口注入（2026-10-17）

✅ 本轮仅容器化 UI 根与相机展示能力。UIContainer 持有唯一 UICameraContainer/CameraState；AppStorage 的实例级 FactoryKit 注册 UI 根及其相机能力，App 提供唯一 CameraCoordinator 构造工厂。Actions 的 Coordinator 注入 CameraCapturing 与 CameraPresenting，通过只读快照判断业务状态，经接口提交视频/姿态及展示投影；原生帧到 UI 值的转换仍在 Coordinator 内，不新增运行时适配层。AgentBindings 提供弱引用、延迟访问运行时的 CameraIntegrationBindings，页面读取 App 注入的同一 state，不再构造 CameraState 或 Coordinator。

✅ App 生命周期图为 storage/platform/ui → agents → native，先关闭展示与原生接纳，再逆序加入消费者及根清理。UI 初始化/启动不打开相机、请求权限或运行模型；失活清空媒体并拒绝新媒体，状态与错误投影仍允许。到期任务替换取消旧任务并加入旧任务，清屏保留完成句柄，UI stop 加入取消链并释放句柄。Metal/GPU 继续由原生视图管理真实完成，UI stop 不代表 GPU 上屏或物理停机。

✅ CameraCapturing 不依赖 UI/业务模块，AppleCamera 实现原生接口；权限和拍照方向读取也经过实例接口。移除 Coordinator 对具体 AppleCamera、CameraCaptureOrientation、CameraState 的依赖。四大基础库仍无相互依赖；FactoryKit 仍仅 AppStorage 导入。不新增目录、编译目标、第三方依赖或签名配置，未自动提交。

- ✅ 专项 17 项通过：UI 13 项、Integration 4 项，覆盖容器实例隔离/子能力缓存一致、停止后旧根不重开、失活拒绝媒体及保留错误投影、快照独立性、独立视频/骨架、真实 Metal、消费者先停止、启动回滚，以及相机接口替身经真实 Gateway 适配保留原生附件和失败。日志 /tmp/mobileharness-ui-container-tests-final.log。最后一次相关复跑包含最终简化后的附件断言。
- ✅ 最终 scripts/check.sh 的静态边界、源码唯一归属/README、严格格式、六项 Python 回归通过，UITests 81 项全部通过。另行针对最终文件执行严格格式、边界脚本、plutil 与 git diff --check 通过。日志 /tmp/mobileharness-ui-container-check-final.log。
- ❌ 最终完整 Integration 950 项中 12 项失败、22 个问题：publicationOverflowDoesNotWaitForDiagnosticCallbacks、atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、七项 soundSource、visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers、visionResolvesOpaqueInputWithoutCopyingMediaIntoObservation、visionRejectsMismatchedCaptureBeforeCallingModel。不宣称全量通过，也不据此断言是既有问题。初轮完整运行 Integration 947 项失败，发生于最后三项 Integration 回归加入前；日志 /tmp/mobileharness-ui-container-check.log。
- ✅ 最终相关复跑各目标共 79 项通过，其中 Integration 71 项，包含本轮新增回归与全量失败涉及用例；不能替代全量通过。日志 /tmp/mobileharness-ui-container-related.log。
- ✅ 最终签名 Debug 真机构建通过，安装并启动于 iPhone 17 Pro。日志 /tmp/mobileharness-ui-container-device-final.log、/tmp/mobileharness-ui-container-install.log、/tmp/mobileharness-ui-container-launch.log。
- ✅ 用户在上述版本安装并启动后，对“开启摄像头检查背景视频和骨架，再切换镜头、进入后台返回并重新开启”的问题反馈“背景、骨架及切换均正常”。这是用户反馈的真机验收，非自动化测量或现场日志采样。
- ❌ scripts/build-ios.sh 在 Simulator 的 CoreAIShared 缺少 CoreAI 依赖处失败，后续 scheme 未执行。日志 /tmp/mobileharness-ui-container-simulator.log。
- ❌ 尚未进行真实 YOLO 故障注入、长时间运行/热状态/FPS 测量或 App 故障重试整根重建的独立真机验收；UI 根替换及清理、原生显示链与错误隔离已有自动化覆盖。其余会话、设置、导航、日志 UI 状态明确不在本轮容器化范围。

## 统一外部 Signal 接入与宿主动态订阅（2026-10-17）

✅ 已迁移全部现有宿主业务输入工厂：AppEnvironmentFact、AppInteractionIntent、ListeningIntent、SpeechCaptureEnded、ProviderDiscoveryIntent、ProviderSettingsIntent、PhotographerCameraIntent、CameraStateObservation、ModelResourceIntent、ModelResourceObservation、ModelResourceHostFailure、MemoryHistoryIntent、AssistantSessionControl、AgentTaskInputIntent。领域仅提供 ExternalInputDraft，不创建 AgentInput/InputMetadata；Gateway 的 ExternalInputAdapter 和通用 input 扩展统一创建外部信封。普通 Signal ID/root 由 Gateway 生成，已有业务请求 ID、来源、序号、parent/hops、deadline 和 turn 按契约保留。相机/麦克风/BLE 适配复用同一入口；外部不能生成执行反馈或 Task 授权。

✅ InputGateway 增加宿主精确动态订阅/取消，限制 schema、目标输入、来源和 publisher 声明，绑定会话/incarnation。静态与动态目标合并分发，外部与 Agent 广播均生效；旧实例关系不被新实例继承。每目标静态/动态关系合计16、动态总数256、话题64、单 contract/source 目标16，超限明确拒绝；不新增消息队列或设备任务。取消阻止后续发布，已接纳发布可完成；shutdown 清空关系并取消/加入发布。拥有者仍需显式取消。宿主会话控制改用订阅目标的 Gateway send，保留原执行取消完成屏障及真实分支拒绝。

✅ 额外传感器已有通用类型化 schema/source 接入路径，专项以合成 sensor.sample 验证无需 Gateway 依赖领域模块。未新增陀螺仪、定位等硬件驱动，也不宣称这些硬件已采集。原生视频仍由 Actions 直接提交 UI；Agent 内部决策派生、可信固定任务解包及运行时反馈保留其专用授权边界，不作为外部输入重新封装。

- ✅ 最终相关回归各目标共135项通过，其中 Integration103项，包含本轮新增10项及设备、业务意图、provider、history、资源和聆听相关回归。新增用例覆盖身份/因果、非法内容/反馈、合成传感器实际分发、静态/动态 Agent 广播、重复/权限拒绝、会话及实例替换、容量回收、关闭加入和实际宿主中断/取消的 Gateway 接纳。日志 /tmp/mobileharness-unified-input-related.log。新增10项在最终全量运行中亦通过。
- ✅ 最终 check.sh 的静态边界、README/源码归属、严格格式和六项 Python 回归通过；另行 plutil 与 git diff --check 通过。业务输入信封及宿主 receive 旁路已加入静态守卫。
- ❌ 最终完整 check.sh 未通过：UITests81项中 cameraNativeMetalDrawStopAndLayerHandoff 失败；Integration960项中11项失败、20个问题，涉及 atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、七项 soundSource、mediaTransportSurvivesExpiryDuringDispatchAndDisplaysNextFrame、visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers、visionRejectsMismatchedCaptureBeforeCallingModel。日志 /tmp/mobileharness-unified-input-check-final.log。初轮全量日志 /tmp/mobileharness-unified-input-check.log，早于最终普通 ID 生成位置调整及分支拒绝封装，不替代最终结果。
- ✅ 上述失败涉及领域的定向复跑 Integration21项通过，包括声音、视觉、媒体、publicationOverflow 与机械臂时限。❌ 同次 UITests 的原生 Metal 用例仍失败：5秒内未满足渲染/清理完成条件，未定位原因，不宣称是既有问题或环境问题。日志 /tmp/mobileharness-unified-input-failures-related.log。定向通过不替代全量通过。
- ✅ 最终签名 Debug 真机构建成功，已安装并启动于 iPhone17 Pro，bundle dev.mobileharness.app，安装序号3868。日志 /tmp/mobileharness-unified-input-device.log、/tmp/mobileharness-unified-input-install.log、/tmp/mobileharness-unified-input-launch.log。安装/启动不代表已完成手工业务验收或真实模型稳定性验证。
- ❌ build-ios.sh 的 MobileHarnessSimulator 仍因 CoreAIShared 无法解析 CoreAI 依赖失败，后续 scheme 未执行。日志 /tmp/mobileharness-unified-input-simulator.log。

本轮未新增目录、编译目标、第三方依赖或硬件权限，未自动提交；保留此前工作区修改。远程输入、持久投递、任意未授权订阅、额外硬件驱动与长时间真机/性能验收仍未实现或未完成。

## 统一容器异常事件通道（2026-10-17）

上一轮 Platform/UI 容器化及统一输入已提交为 14532dfd；本轮容器异常通道未自动提交。此前保留的 XML 参数改动由工作区其他工作另行提交为 a77b30fe，本轮未混入该改动。

✅ Storage/Platform/UI 使用各自基础库拥有的原生错误回调，不依赖 Signal/Gateway。App 的实例级注册缓存唯一 ContainerFailureChannel，把同根回调及服务 start/foreground/stop/cleanup 失败接到通道；diagnostics 先启动、最后停止。State、缓存与音频句柄/流、Files/文档/字节、SQLite 读写/准备/迁移/关闭，原生相机、录音/提示音/触觉、BLE/串口以及 UI renderer 已接入相应错误路径。原始 throw、错误类型、主因/清理因及真实完成语义保留；文件或模型制品清理失败后仍尝试关闭 Storage，不把停止失败当作完成。

✅ Gateway 使用标准 container.failure observation，来源 runtime，origin 为 external；不会赋予运行时反馈/执行权限。每根128条故障、64个待投递键、8个 newest-one 观察者，一个有主人的 worker；重复组件/操作/阶段/代码/描述合并为同一记录并计数，满容量淘汰最旧并计数。基础库回调不 await、不逐事件创建 Task。投递入口错误只更新状态，不递归生成新故障；停止取消/加入 worker，迟到报告拒绝计数。published 仅表示向 Gateway publish 入口提交，不等同 Agent 接纳/处理或设备完成回执；未连接/关闭阶段仍保留日志，不伪造送达，也不跨根重放旧队列。

✅ 默认 Assistant 显式订阅并在128条有界内存中被动接纳；不写可能已故障的 Storage、不启动模型。AgentBindings 的通道快照投影到现有运行异常与 toast，同一事件 ID 更新行及次数，不重复弹 toast。常规调用方取消、明确的接纳失活及媒体过期不升级；生命周期认定的服务意外取消仍保留为故障。原有 ActionResult、设备事件及业务诊断仍保持各自语义，不被伪装成容器执行结果。无须业务为每个容器另装监听；自建 SDK 后端仍由构造者显式注入原生报告器。

- ✅ 专项11项通过，其中新增10项及增强的 Platform 清理回归。包含真实原生回调/Storage叶子操作 → Gateway → Assistant → 运行异常/toast、原错误保留、被动无模型/无持久化、根缓存与隔离、启动前及回滚、重复计数/无重复 toast、日志/待投递/观察者容量、坏来源/事件拒绝、发布失败不递归与重连、关闭后拒绝及非合作发布的真实加入。日志 /tmp/mobileharness-container-failure-tests-final.log。全量运行中这11项亦通过。
- ✅ 相关定向回归各目标共240项通过，其中 Integration181项，覆盖 State/Cache/Files/SQLite、生命周期、通信、统一输入和相机根。日志 /tmp/mobileharness-container-failure-related.log。
- ✅ check.sh 的模块/依赖/源码归属/README、严格格式及六项 Python 回归通过。新增守卫检查 App 同根报告器与 diagnostics 生命周期、Gateway 不反向依赖基础能力实现。另行 git diff --check、plutil 通过。
- ❌ 完整 check.sh 未通过：UITests81项中 cameraNativeMetalDrawStopAndLayerHandoff 失败；Integration974项中11项失败、24个问题，包括 atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、七项 soundSource 常规回归及 soundSourceContextWriteFailureReportsWithoutStoppingOrSelfJoin、visionResolvesOpaqueInputWithoutCopyingMediaIntoObservation、visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers。日志 /tmp/mobileharness-container-failure-check.log。不能认定全量通过，也未证明失败均为既有问题。
- ✅ 上述失败相关定向复跑 Integration18项通过。❌ 同次原生 Metal 用例仍在5秒渲染/清理条件等待处失败，原因未定位；不以定向通过替代全量通过。日志 /tmp/mobileharness-container-failure-failures-related.log。
- ✅ 最终签名 Debug 真机构建通过，安装并启动于 iPhone17 Pro，bundle dev.mobileharness.app，安装序号3876。日志 /tmp/mobileharness-container-failure-device-final.log、/tmp/mobileharness-container-failure-install.log、/tmp/mobileharness-container-failure-launch.log。早期设备构建也通过，但最终结果以上述日志为准。
- ❌ build-ios.sh 的 MobileHarnessSimulator 仍因 CoreAIShared 无法解析 CoreAI 依赖失败，后续 scheme 未执行。日志 /tmp/mobileharness-container-failure-simulator.log。
- ❌ 尚未对真实 iPhone 系统中断、硬件故障及真实渲染失败进行独立故障注入验收；安装/启动和替身测试不能代替这些场景。进程崩溃后的持久日志、远程遥测、硬件自动恢复及尚未容器化的 ModelKit 根不属于本次已实现能力。

未新增目录、编译目标、第三方依赖、硬件权限或模型函数。普通视频/姿态渲染链路保持既有设计。

## ApplicationControl 统一异常展示（2026-10-18）

本轮在未提交的统一容器异常通道之上调整展示所有权，保留既有工作区修改，不自动提交。模块组合装配仍保留当前 App/AgentBindings 边界，未将跨模块组装迁到 App。

- ✅ 容器经 Gateway 的 container.failure Signal、既有执行/本地诊断经 runtime.failure Signal，进入 ApplicationControl 的确定性异常策略，再由内部 UI.RuntimeDiagnostics.recordFailure 实际更新首页 UI。移除 ActionActivityWorkflow 容器快照直达 UI 及提示策略，保留 App 启动失败兜底和 Assistant 可选被动诊断。
- ✅ 相关定向24项通过，包括无模型/无持久化、重复计数、过期记录不弹窗、暂停接纳、伪造/过期/停止拒绝、容量、呈现失败防递归、模型/语音文案及机械臂关联信息。日志 `/tmp/mobileharness-application-control-related.log`。视觉终态真实 OutputGateway 到 ApplicationControl 的用例在后续完整运行中也已通过，最终完整结果另列。
- ✅ 静态依赖/源码归属/README、严格格式、六项 Python 回归通过；新增守卫禁止绑定层直接呈现异常并检查角色订阅与呈现授权。`git diff --check`、Xcode project/privacy/entitlements 的 plutil 检查通过。
- ✅ 签名 Debug 真机构建成功，包含 Actions 新入口源码的实际 arm64 编译：`/tmp/mobileharness-application-control-device.log`。随后按用户要求已安装并启动于 Youwei’s iPhone 17 Pro，bundle dev.mobileharness.app，安装序号3908；日志 `/tmp/mobileharness-application-control-install.log`、`/tmp/mobileharness-application-control-launch.log`。尚未进行真实故障注入验收，不将安装/启动当作真机异常展示验收。
- ❌ `build-ios.sh` 的 MobileHarnessSimulator 在 CoreAIShared 无法解析 CoreAI 依赖处失败，后续 scheme 未执行：`/tmp/mobileharness-application-control-simulator.log`。
- ❌ 早期完整检查暴露旧测试仍期待绑定层同步直接投影；已把相应策略用例迁入真实 Gateway/ApplicationControl 链路，视觉终态用例也增加相同呈现接入。早期日志 `/tmp/mobileharness-application-control-check.log`、`/tmp/mobileharness-application-control-check-final.log` 不代表最终源码验证结果。
- ❌ 最终完整检查未通过：`/tmp/mobileharness-application-control-check-final2.log`。UITests 81项中 cameraNativeMetalDrawStopAndLayerHandoff 失败；Integration 984项中11项失败、20个问题，分别为 atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、七项 soundSource 常规回归、soundSourceContextWriteFailureReportsWithoutStoppingOrSelfJoin、mediaTransportSurvivesExpiryDuringDispatchAndDisplaysNextFrame、visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers。AppWorkflowTests 115项全部通过；本轮异常链路相关用例在完整运行中通过。未证明其余失败均为既有问题，不宣称全量通过。
- ✅ 最终相关及失败领域定向复跑43项全部通过：`/tmp/mobileharness-application-control-final-related.log`。包含本轮25项相关用例，以及声源、媒体、视觉超时恢复、机械臂时限相关回归；未以定向通过替代全量结论，原生 Metal 失败仍未定位。

异常原始抛错、设备事件、ActionResult 和清理完成语义保持原有接口。Signal 提交不代表 Agent 已接纳或 UI 已呈现；展示失败有界保留，未新增持久遥测、进程崩溃恢复、自动重试或硬件恢复。

## UI 全量容器化（2026-10-18）

本轮扩展同一 App 缓存的 UI 根，拥有 home、camera、settings、modelResources、navigation、history、devices、diagnostics 八个子容器。业务消费者经 UI 自有呈现接口更新，页面观察同根状态；生产状态构造归 UI。FactoryKit 仍只用于 App，保留 AgentBindings/ActionBindings 编译目标及当前装配边界，未新增目录、目标或依赖，未自动提交。

- ✅ 生命周期及专项自动化覆盖根隔离与注册一致、无副作用初始化、共享展示状态、前后台分类接纳、跨根/失活代际拒绝、停止后的迟到更新、敏感草稿清理、重新建根、Toast 到期任务加入、表情等待解除、设置 revision、资源 generation、历史分页及启动前最新设备快照。最终相关与失败领域定向复跑共134项通过：UI28项、额外目标1项、Integration88项、AppWorkflow17项。日志 `/tmp/mobileharness-ui-full-final-related.log`。定向通过不能替代全量通过或真实硬件验收。
- ✅ 完整检查中的静态依赖、源码归属、README、严格格式及六项 Python 回归通过；UITests81项、AppWorkflowTests115项全部通过。日志 `/tmp/mobileharness-ui-full-check.log`。此次原生 Metal 回归通过，不覆盖历史失败记录。
- ❌ 完整检查未通过：Integration994项中13项失败、24个问题。涉及 nexArmPlaybackCongestionRejectsWithoutReplayingMotion、atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、八项 soundSource（含 ContextWriteFailure）、mediaTransportSurvivesExpiryDuringDispatchAndDisplaysNextFrame、visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers、visionResolvesOpaqueInputWithoutCopyingMediaIntoObservation。未证明这些失败均为既有或环境问题；定向复跑通过不消除全量失败结论。
- ✅ 最终签名 Debug 真机构建通过：`/tmp/mobileharness-ui-full-device-final.log`。安装并启动于 Youwei’s iPhone 17 Pro，bundle dev.mobileharness.app，安装序号3916；日志 `/tmp/mobileharness-ui-full-install.log`、`/tmp/mobileharness-ui-full-launch.log`。随后进程查询仍可见本应用，不能据此认定页面行为正确。
- ❌ `build-ios.sh` 在 Simulator 的 CoreAIShared 无法解析 CoreAI 依赖处失败，后续 scheme 未执行：`/tmp/mobileharness-ui-full-simulator.log`。
- ❌ 真机验收未通过。用户对首页字幕/提示、设置/资源、导航/历史、蓝牙、相机及前后台检查反馈“有异常，我补充具体场景”；已请求具体页面、操作、预期及实际行为，等待补充以定位。安装/启动与替身测试不代表这些交互已验收通过。真实模型稳定性、长时间 FPS 和故障恢复仍须独立记录。

### 真机反馈：字幕时短暂停顿与相机忙碌提示（2026-10-18）

用户反馈回复字幕出现时视频短暂停顿，以及相机打开后出现“相机操作正在执行，请稍后重试”；补充确认后者是在开启后再次点击其他相机按钮触发。代码确认 CameraInteractionWorkflow 的重叠保护把提示写入设备 message，且没有在请求完成时撤销；按钮仅依据原生 isBusy，未覆盖 Gateway/Agent 请求尚未完成的窗口。

- ✅ CameraInteractionWorkflow 改为注入同根 CameraPresenting；请求提交同步投影 controlBusy，结束时清理独立 controlMessage/忙碌状态。界面在控制请求或原生操作期间禁用开启/关闭、切换与重试，保留程序化重叠拒绝及设备错误。提示并不代表设备失败，不新增请求队列。
- ✅ 原生表情/光环拆为独立观察子视图；字幕文本不再与原生效果处于同一观察 body。相机与光环布局只在 frame/scale/drawableSize 实际变化时写图层几何，相机尺寸写入关闭隐式事务。仍使用原有独立视频、姿态和 Metal 渲染线程。这是针对多余渲染工作的优化，尚未通过性能采样证明它是卡顿的全部原因。
- ✅ 最终定向80项通过（UI23、Integration41、AppWorkflow16），包含新增的同步忙碌/重叠提示清理/设备错误隔离、八项 UI 根回归及原生 Metal 回归：`/tmp/mobileharness-ui-feedback-related-final.log`。
- ✅ 静态边界/归属/README、严格格式、六项 Python 回归通过；另行边界、修改文件格式、git diff --check 和 project/privacy/entitlements 检查通过。日志 `/tmp/mobileharness-ui-feedback-boundaries.log`、`/tmp/mobileharness-ui-feedback-format.log`。
- ❌ 完整检查未通过：`/tmp/mobileharness-ui-feedback-check.log`。UITests81项、AppWorkflowTests116项通过；Integration994项中14项失败、24个问题：nexArmIntermediateTimeoutAdvancesAndReportsMissingSegmentAfterEnding、nexArmPlaybackCongestionRejectsWithoutReplayingMotion、uiFullHomeOwnsToastExpiryWithoutAViewAndStopJoinsEffects、atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、七项 soundSource、visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers、mediaTransportSurvivesExpiryDuringDispatchAndDisplaysNextFrame、visionRejectsMismatchedCaptureBeforeCallingModel。UI 到期测试在两秒等待条件超时，后续定向通过；不据此认定全部失败为环境或既有问题，不把复跑通过替代全量通过。
- ❌ Simulator 构建仍在 CoreAIShared 无法解析 CoreAI 依赖处失败，后续 scheme 未执行：`/tmp/mobileharness-ui-feedback-simulator.log`。
- ✅ 最终签名真机构建成功：`/tmp/mobileharness-ui-feedback-device-final.log`。早期使用独立构建缓存的签名构建主动中断，改用已有缓存续建；`/tmp/mobileharness-ui-feedback-device.log` 不作为成功证据。
- ✅ 重试安装成功于 Youwei’s iPhone 17 Pro，bundle dev.mobileharness.app，安装序号3924：`/tmp/mobileharness-ui-feedback-install-retry.log`。首次安装在建立 CoreDevice 通道时连接中断并超时（error4000 / NWError60）：`/tmp/mobileharness-ui-feedback-install.log`；保留该失败，不以重试抹除。
- ❌ 启动被锁屏拒绝（FBSOpenApplicationErrorDomain Locked）：`/tmp/mobileharness-ui-feedback-launch.log`。已请用户解锁并打开应用；本次两个场景的真机交互验收尚未完成，安装不等于字幕性能或按钮行为已通过验收。

### 字幕卡顿继续定位：真机采样与主线程频谱（2026-10-18）

❌ 用户对安装序号3924反馈“字幕出现时仍卡顿”，因此上一轮优化没有通过该场景验收，不能将它记为卡顿修复完成。

✅ 本次在 iPhone 17 Pro 上使用 Time Profiler 启动当前应用并录制50.665秒，用户在采集期间确认“已复现卡顿”。原始记录 `/tmp/mobileharness-caption-reproduced.trace`，导出 `/tmp/mobileharness-caption-samples.xml`、`/tmp/mobileharness-caption-hangs.xml`，分析 `/tmp/mobileharness-caption-analysis.txt`、`/tmp/mobileharness-caption-bursts.py`。原始 trace 只保留在本机临时位置，未纳入仓库。

采样显示麦克风消费者在 MainActor 同步调用 AudioSpectrum.measure；10秒后的主线程 FFT 累计采样权重约608ms，非单次耗时。主线程同时出现 SwiftUI 图更新和原生字幕初始化/UILabel 字体路径；32.252至32.267秒附近的密集主线程片段含13个采样点。未记录到超过250ms的主线程 hang。没有统一字幕/视频时间标记或真实上屏 FPS，不能认定上述某一项就是全部卡顿原因，也不能据此认定 YOLO 崩溃或 GPU 卡死。

- ✅ 麦克风与播放 FFT 改用 PlatformKit 的 `@concurrent` measureOffMain，在通用执行器执行有界2048点计算；只抛 CancellationError。调用者持有原任务并等待，不新增 PCM 队列、后台订阅或逐包独立 Task。麦克风返回后复核 voice generation/capture epoch/handlingTurn/UI token；播放只在主线程提取 tap 快照，返回后复核播放 token 和业务会话，失效采样返回 nil，不把旧结果当有效静音或新播放的结果。
- ✅ 首页识别与回复的原生字幕视图常驻挂载，只更新文字与可见性；空字幕不暴露辅助功能或拦截触摸，保留 Notice/失败状态优先级、任务几何、尾部滚动与文字动画。
- ✅ 定向27项通过（UI8、Integration14、AppWorkflow5），覆盖频谱结果一致与取消、八项 UI 根回归、字幕及原生 Metal：`/tmp/mobileharness-caption-related-final.log`。同步 FFT 仍作为纯计算接口保留，生产两个频谱消费者均使用异步入口。
- ✅ 完整检查中的 UITests81项、AppWorkflow116项、静态边界/归属/README、严格格式、六项 Python 回归通过，另行格式、git diff --check 与 plutil 通过。
- ❌ 完整检查未通过：Integration995项中9项失败、17个问题，涉及 atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、七项 soundSource，以及 visionResolvesOpaqueInputWithoutCopyingMediaIntoObservation；日志 `/tmp/mobileharness-caption-check.log`。不把定向通过替代全量通过，也未证明这些失败均为既有或环境问题。
- ❌ Simulator 仍在 CoreAIShared 无法解析 CoreAI 依赖处失败，后续 scheme 未执行：`/tmp/mobileharness-caption-simulator.log`。
- ✅ 签名真机构建通过：`/tmp/mobileharness-caption-device.log`；安装于 iPhone 17 Pro，序号3932：`/tmp/mobileharness-caption-install.log`。
- ❌ 同场景复测/采样结果待补充；当前不宣称字幕卡顿已解决。

### 再次复现与正常音频释放误报（2026-10-18）

❌ 安装序号3932的复测仍卡顿。用户补充这几次均出现“基础能力模块异常”，Agent 日志为 `storage.cache.audio.stream`、`fail:missing`，提供会话 `859925BB-A555-4C23-ABFD-C01837334412`。这条会话关联来自用户反馈，未读取手机内完整对话或自行推断其他会话。

✅ 第二次限时90秒采样保存为 `/tmp/mobileharness-caption-after.trace`，导出 `/tmp/mobileharness-caption-after-samples.xml`，分析 `/tmp/mobileharness-caption-after-analysis.txt`。主线程未采到 AudioSpectrum.measure，确认频谱计算执行域调整已生效；但用户明确反馈仍卡顿，不能把执行域调整当作性能验收通过。采样仍显示 SwiftUI 图更新，以及 CameraConversationSurface/ConversationView 的高频更新；两次工作负载和时长不同，不直接比较总 CPU 权重来声称帧率改善。

发现确定的正常路径误报：MemoryLeaseStore.release 原先调用 fail(StorageError.missing)，AudioCache 将其送入 AudioStream.fail，统一报告器把正常回收当作真实故障。该路径会在正常播放成功、读完和释放后触发，并不意味着用户音频确实丢失。

- ✅ 移除回调增加明确 MemoryLeaseRemoval.released/failure 原因；正常释放使用 AudioStream.retire 失效旧流，不报告执行故障。保留 missing tombstone、单次 checkout、释放后访问失败及原生产者取消加入；真实失败/过期仍走原 fail/report。没有全局过滤 missing，也未在 Gateway 或 ApplicationControl 隐藏真实错误。
- ✅ 相机背景、视线环境、控制条、统计和照片拆为独立观察子视图；eyeGaze 只由表情子视图读取，麦克风/播放频谱只由波形子视图读取，避免高频输入直接重建整棵首页。UI 状态和实例归属不变，没有新增模块、目录、队列或媒体编码。
- ✅ 最终定向40项通过（UI8、Integration27、AppWorkflow5），包含真实 CacheContainer/AudioCache/故障通道的正常播放释放无故障、真正缺失/流失败仍上报、取消加入、原句柄 missing 语义、频谱、UI 根、字幕及 Metal：`/tmp/mobileharness-caption-cache-related-final.log`。早期语音/容器相关运行另见 `/tmp/mobileharness-caption-cache-related.log`。
- ✅ 完整检查的 UITests81项、AppWorkflow116项、静态边界/归属/README、严格格式及六项 Python 回归通过。
- ❌ 完整检查未通过，Integration996项中11项失败、20个问题：uiFullHomeOwnsToastExpiryWithoutAViewAndStopJoinsEffects、atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、七项 soundSource、visionResolvesOpaqueInputWithoutCopyingMediaIntoObservation、soundSourceContextWriteFailureReportsWithoutStoppingOrSelfJoin。日志 `/tmp/mobileharness-caption-cache-check.log`。UI 到期等待仍在完整并发运行中超时，后续定向通过；保留全量失败，不认定都是环境问题。
- ✅ 签名真机构建成功并安装于 iPhone 17 Pro，序号3940：`/tmp/mobileharness-caption-cache-device.log`、`/tmp/mobileharness-caption-cache-install.log`。
- ❌ Simulator 仍在 CoreAIShared 无法解析 CoreAI 依赖处失败，后续 scheme 未执行：`/tmp/mobileharness-caption-cache-simulator.log`。
- ❌ 安装序号3940的第三次采样被锁屏阻止；Instruments 明确提示等待解锁并取消，`/tmp/mobileharness-caption-profile-final.log`，devicectl 亦确认 passcodeRequired=true（`/tmp/mobileharness-caption-cache-lock.log`）。`/tmp/mobileharness-caption-final.trace` 不是有效场景采样，不能当作性能对比证据。已请求用户解锁并保持亮屏，等待同场景复测；卡顿与真实模型稳定性尚未宣称通过。

### 开启聆听时 routeChanged 误报（2026-10-18）

用户反馈安装序号3940“打开聆听，立马就 toast 基础模块异常，异常内容 routeChanged，container:failure”，并确认已解锁保持亮屏。这与前面的正常 PCM 释放误报是不同路径，未把前一项修复当作全部错误已解决。

✅ 代码确认 AppleAudioIO 直接把路由变化通知报告为容器故障，且未区分中断 began/ended。按 [Apple 路由原因定义](https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangereason)，categoryChange/override 包括应用引起的配置变化；本实现将其与设备身份变化分开处理，而不把原始通知一律视为执行失败。

- ✅ NativeAudioEvent 恢复为非 Error 的设备事实；routeChanged 不再直接进入 container.failure。categoryChange/override 及前后输入/输出 portType+UID 相同的重配不要求停止聆听；真正端口变化、无可用路由及无法获取旧快照时仍保守投递 routeChanged。实际格式/连续性、overflow、启动、播放、清理错误仍保持原上报。中断只在 began 且本实例有活动捕获/播放时上报 AudioIOError.interrupted，ended 不重复终止或误报；音频检测映射到已有中断提示。
- ✅ 新增同设备配置、端口顺序、输入/输出设备切换、路由丢失、不可用及缺失旧快照的策略回归；源码守卫禁止 routeChanged 直接报故障，禁止 NativeAudioEvent 重新采用 Error。
- ✅ 最终定向45项通过（UI8、Integration32、AppWorkflow5）：`/tmp/mobileharness-audio-route-related-final.log`。完整检查失败涉及的 agentProtocolFailureProjectsShortToastFullDetailAndCorrelation 单独复跑1项通过：`/tmp/mobileharness-audio-route-diagnostic-recheck.log`；不能据此消除全量失败。
- ✅ 最终完整检查的静态边界/源码归属/README、严格格式、六项 Python 回归、UITests81项、AppWorkflow116项通过；另行 git diff --check、plutil 通过。
- ❌ 最终完整检查未通过：Integration997项中15项失败、29个问题，包括 nexArmPlaybackCongestionRejectsWithoutReplayingMotion、uiFullHomeOwnsToastExpiryWithoutAViewAndStopJoinsEffects、agentProtocolFailureProjectsShortToastFullDetailAndCorrelation、atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、七项 soundSource、visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers、mediaTransportSurvivesExpiryDuringDispatchAndDisplaysNextFrame、visionResolvesOpaqueInputWithoutCopyingMediaIntoObservation、soundSourceContextWriteFailureReportsWithoutStoppingOrSelfJoin。日志 `/tmp/mobileharness-audio-route-check-final.log`。早期完整检查 `/tmp/mobileharness-audio-route-check.log` 早于最终事件类型与检测错误映射，不替代最终结果；未证明其余失败均为既有或环境问题。
- ❌ 首次签名构建发现 AudioDetectionSession 对新增中断错误的 switch 不完整，已补齐；保留失败日志 `/tmp/mobileharness-audio-route-device.log`。
- ✅ 最终签名真机构建通过、安装并启动于 iPhone17 Pro，安装序号3948：`/tmp/mobileharness-audio-route-device-final.log`、`/tmp/mobileharness-audio-route-install.log`、`/tmp/mobileharness-audio-route-launch.log`。
- ❌ Simulator 仍在 CoreAIShared 无法解析 CoreAI 依赖处失败，后续 scheme 未执行：`/tmp/mobileharness-audio-route-simulator.log`。
- ❌ 同场景真机 Toast/视频验收正在进行。直接附加进程的 Instruments 尝试未匹配进程（`/tmp/mobileharness-audio-route-profile.log`）；随后使用 bundle 启动采集（`/tmp/mobileharness-audio-route-profile-launch.log`），成功开始后已请求用户复现，结果待补充。不把失败的附加尝试或安装启动当作性能验收。


### 路由修复复测与逐段视频时序（2026-10-18）

✅ 用户确认序号3948“无误报”；❌ 同场景视频仍卡顿。有效采样已保存 `/tmp/mobileharness-audio-route-profiled.trace`，不能将路由修复或 CPU 热点变化视为视频性能通过。待加入逐段帧时序标记并重新采集，区分原生取帧、主线程交付、SwiftUI 提交和 GPU 完成延迟。

用户补充：卡顿只在回复开始时出现，回复中间和后续流畅，并怀疑顶部频谱。代码确认 VoiceBars 为常驻 Canvas（32 柱条及模糊光晕），不在其内执行 FFT；实际绘制执行域与延迟需采样判定。已实现 CameraCaptured/Received/Accepted/SurfaceSubmitted/GPUCommitted/GPUCompleted 事件，以及 SpectrumDraw、PlaybackConfigure、PlaybackSchedule 区间；记录范围只含帧序号、GPU 状态和频谱位置/激活布尔值。未改变相机/音频执行域或渲染策略，不将新增诊断当作修复。

- ✅ 签名真机构建通过，安装序号3956并启动：`/tmp/mobileharness-camera-timing-device-final.log`、`/tmp/mobileharness-camera-timing-install.log`、`/tmp/mobileharness-camera-timing-launch.log`。只增加时序诊断，视频卡顿仍待定位。
- ✅ 完整检查的源码边界/归属、README、严格格式及六项 Python 回归通过，UITests81项和 AppWorkflow116项通过；git diff --check 通过。
- ❌ 完整检查未通过：Integration997项中10项失败、19个问题。失败为 nexArmPlaybackCongestionRejectsWithoutReplayingMotion、七项 soundSource、mediaTransportSurvivesExpiryDuringDispatchAndDisplaysNextFrame、visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers。证据 `/tmp/mobileharness-camera-timing-check-final.log`；不认定均为环境问题。首次检查因新增 UI 系统 os 导入未登记而失败（`/tmp/mobileharness-camera-timing-check.log`），已限定到具体实现文件放行并重新执行。
- ❌ Simulator 仍因 CoreAIShared 无法解析 CoreAI 依赖失败，后续 scheme 未执行：`/tmp/mobileharness-camera-timing-simulator.log`。
- 实机 Time Profiler 已开始采集 `/tmp/mobileharness-camera-timing.trace`（日志 `/tmp/mobileharness-camera-timing-profile.log`），请求用户连续两次回复以区分每次开头与首次冷启动；不得提前标为性能通过。

### 回复开始阻塞定位与原生频谱（2026-10-18）

用户确认诊断版仍在回复开头卡顿，并要求盘点 Canvas、优先采用 Apple 原生动画。逐段时序采样已保存并导出 `/tmp/mobileharness-camera-timing-signposts.xml`。导出包含重复表事件，计数需去重，不把重复项当作多次播放。

- ✅ 两个 PlaybackSchedule 区间为39.393317583–40.085747458秒、67.363836541–68.054423708秒，分别692.430、690.587ms。对应 CameraReceived 的间隔约701.6、703.7ms，SurfaceSubmitted/GPUCommitted 同时停顿；原生 CameraCaptured 在这两段持续产生，活动段回调间隔约40ms以内。SpectrumDraw 最长约0.105ms，并非这两次约700ms停顿的主要 CPU 阻塞。GPU 完成不代表物理上屏；不排除其他场景的额外卡点。
- ✅ NativePlaybackGraph 私有 actor 拥有输出引擎、播放器、格式、tap 安装及原生提交。AppleAudioIO 主线程仅保留接纳、token 和真实 dataPlayedBack 等待；停止同步失效并由单个清理任务加入原生停止，根停止/下一播放/会话清理均加入。最多三个已调度缓冲和一个串行提交；不通过增大缓冲掩盖阻塞。prepareClip/discardPreparedClip 及游标读取为 async，UI 启动不激活设备。
- ✅ UI 唯一 Canvas 使用点是 VoiceBars 的顶部/底部频谱，已改为常驻 UIView、CAGradientLayer/CAShapeLayer 和 CABasicAnimation 路径插值，无逐帧 timer。眼睛/光环/字幕/视频已有原生实现；保留 SwiftUI 的有限照片/透明度/布局动画及其真实完成回执。ActionActivityView 的半秒 TimelineView 只刷新耗时文本，保留。八个子容器原本已在根 init 全部创建，本轮不伪造另一套容器预加载或在 boot 打开设备。
- ✅ 新增两项几何回归通过；定向 UI 根8项通过。定向 Metal 回归仍失败（5秒 predicate 超时），不能把定向运行记为全通过：`/tmp/mobileharness-native-playback-targeted.log`。
- ❌ 首次检查因新增测试 CGFloat.infinity 推断歧义而编译失败，已显式指定 CGFloat；首次签名构建因原生频谱日志隐式 self 而失败，已补齐。保留 `/tmp/mobileharness-native-playback-check.log`、`/tmp/mobileharness-native-playback-device.log`。
- ✅ 最终签名真机构建成功，安装序号3964并启动：`/tmp/mobileharness-native-playback-device-final.log`、`/tmp/mobileharness-native-playback-install.log`、`/tmp/mobileharness-native-playback-launch.log`。最终源码边界、严格格式及 git diff --check 通过。
- ❌ 完整检查未通过：UITests83项中 cameraNativeMetalDrawStopAndLayerHandoff 失败；Integration997项中13项失败、23个问题（UI Toast 到期、atomic 稳定离靶、七项 soundSource、媒体到期传输、Vision 预算恢复、soundSourceContextWriteFailureReportsWithoutStoppingOrSelfJoin、Vision 不复制媒体）。AppWorkflow116项、静态检查和 Python 回归通过。证据 `/tmp/mobileharness-native-playback-check-final.log`；未证明失败均为环境问题。
- ❌ Simulator 仍在 CoreAIShared 解析 CoreAI 处失败，后续 scheme 未运行：`/tmp/mobileharness-native-playback-simulator.log`。
- ❌ 首次复测采集提示目标进程退出，手机另有当前安装路径的运行实例，不能把该次采集当作同场景性能通过（`/tmp/mobileharness-native-playback-profile.log`）。已结束该实例并重新由 Instruments 启动采集：`/tmp/mobileharness-native-playback-profile-recheck.log`，等待用户复现及完整时序分析。

✅ 重新启动后的90秒采样已完成：`/tmp/mobileharness-native-playback-recheck.trace`，导出 `/tmp/mobileharness-native-playback-signposts.xml`、去重分析 `/tmp/mobileharness-native-playback-analysis.txt`。PlaybackSchedule 在67.454474208–68.167657416秒等待713.183ms；同一区间有21次原生捕获/接收、42次表面提交、40次 GPU 提交/完成，相邻事件最大间隔依次为38.410、38.582、26.803、33.352、39.108ms。这直接证明本次原生启动等待期间主线程仍可交付相机帧，未重现此前与播放启动对应的约700ms停顿；不把等待区间时长误读为主线程占用，也不将 GPU 完成当作屏幕回执。

❌ 此采样66.077–66.428秒仍有一次约350ms的原生捕获及下游同步间隔，发生于播放启动之前；未获操作关联，不能认定其原因或把所有卡顿判为解决。原生频谱图层提交最长约0.289ms，未据此宣称比 Canvas 的 CPU 用时更低。用户对新版画面、频谱外观、停止播放及前后台的手工验收仍待回复。


### UI 代码与文档整理（2026-10-18）

用户要求清除无功能用途和对比代码、合并同类文件、统一格式及当前文档。已先更新总体、UI 各目录、相关集成、工程、测试及源码守卫 README 为待实施。计划清理视觉演示／模拟记录、成套临时时序 signpost 和旧 sensorPoint 投影；合并状态／接口／子容器，保留真实诊断与 GPU／动画回执。现有采样证据作为历史保留，不将清理算作性能问题验收通过。本轮不提交。

- ✅ UI Swift 源码由47个归并为39个：Provider／资源操作接口与所属状态合并，运行日志值与异常接口归日志状态，五个散放的子容器分别归所属功能文件。NavigationState／UINavigationContainer／导航协议归 UIContainer，音频检测状态及 Section 归 Diagnostics/AudioDetectionWorkflow。眼睛包装归 NativeCompanionSurface，频谱归 VoiceBars。根八子容器、App 缓存和原有消费者注入不变。
- ✅ 删除 ConversationVisualPreview／ActionActivityVisualPreview、视觉模拟启动参数及模拟记录；保留实际聊天／MOSS／音频检测诊断。成套移除 UI、相机输入／执行层及音频播放的临时比较 signpost，保留播放 actor 修复、运行错误日志和真实 GPU 完成计数。删除 sensorPoint 旧预览投影及只验证它的断言，保留非法 Pose payload 拒绝和生产网格校验。
- ✅ 公开名称核对：仅移除上述两个演示类型／body 和旧 sensorPoint 方法，其余公开名称无增删。UI 导入按字母顺序统一，声明属性独立行并通过严格格式；表情／效果协议与实现同文件，签名构建不再出现原先的异文件 Sendable conformance 警告。
- ✅ 重写七份 UI README 为统一的职责、接口、文件归属、生命周期、失败与待完成项，删除旧实现、追加式重复和无关业务细节。总体及相关模块、工程、脚本和测试文档同步。工程中不存在指向已删除 UI Swift 文件的引用，UI README 相对链接均有效；SwiftPM 仍唯一编译 UI，无新目录／target／依赖。
- ❌ 首次源码守卫因中立操作协议／错误值合并到 ModelResourcesState 文件而误判业务执行，已调整为只排除中立协议和错误值声明，仍检查整个文件及扩展的异步执行／安装策略；最终守卫通过：`/tmp/mobileharness-ui-cleanup-boundaries-final.log`。早期失败保留 `/tmp/mobileharness-ui-cleanup-boundaries.log`。
- ✅ 定向12项通过（频谱几何2项，UI根8项、表情取消1项、非法Pose拒绝1项）：`/tmp/mobileharness-ui-cleanup-targeted.log`。完整检查的静态边界、README归属、严格格式、六项Python回归及AppWorkflow116项通过；最终单独UI格式、git diff --check及工程／隐私／权限plutil通过。
- ❌ 完整检查未通过：UITests83项中cameraNativeMetalDrawStopAndLayerHandoff超时失败；Integration997项中11项失败、20个问题，为uiFullHomeOwnsToastExpiryWithoutAViewAndStopJoinsEffects、atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、七项soundSource、visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers、visionResolvesOpaqueInputWithoutCopyingMediaIntoObservation。`/tmp/mobileharness-ui-cleanup-check.log`。定向UI到期通过不消除全量失败；未断言其余失败都是环境问题。
- ✅ 签名真机构建通过：`/tmp/mobileharness-ui-cleanup-device.log`。
- ❌ Simulator仍在CoreAIShared无法解析CoreAI处失败，后续scheme未运行：`/tmp/mobileharness-ui-cleanup-simulator.log`。
- 本轮未重新安装或操作手机，未进行新的真实模型／帧率／原生交互验收，未提交。原始源码整理前快照仅存于本地临时备份，历史性能采样留在既有验证证据中，不参与生产编译。

### 其他基础模块边界与冗余审查（2026-10-18）

用户要求高内聚、对外协议解耦、基础模块不依赖其他框架模块及数据／代码风格一致，Signal 转换保留 Gateway。已先阅读并更新总体、PlatformKit/Audio/Vision、Storage/错误/音频/文件、ModelKit/Management/Hub、相关消费者、Gateway、工程、脚本及测试说明为待实施。确认无其他基础／业务模块反向导入；ModelKit 仍为进程级 manager，不冒充已完成 App 根容器化。计划以协议输出相机／音频、移除无人调用的预热／游标、减少音频接纳重复报告、合并共享错误及复用一次制品恢复计划读取。保留模型制品旧暂存迁移、内存后端及有实际用途的诊断。无新目录或依赖，不提交。

- ✅ AudioContainer 对外返回 AudioInputOutput／CuePlaying／HapticFeedbackProviding，VisionContainer 返回 CameraCapturing，串口返回 NexArmObservableLink；具体原生实例仍由容器缓存。语音会话、音频检测、原生反馈、拍照提示音及合成诊断改为协议注入；实际缓冲、token、取消、dataPlayedBack和停止加入保持。
- ✅ 删除无框架调用的 prepareClip/discardPreparedClip、playbackSampleOffset 及配套原生actor预热／游标方法、标记和状态；健康输出图复用、触觉实际prepare及Cue原生prepare/play保持。没有回退播放启动隔离修复。
- ✅ CameraEvent 使用String/Sendable原生事实，实际中断／运行失败通过CameraError或原NSError报告；NativeAudioEvent保持非Error。Gateway统一编码两类事件，编解码仅依赖跨平台值，不再受多余iOS编译限制；基础模块不携带Signal会话／来源身份。
- ✅ StorageError.swift集中通用／文档／记录错误，独立类型及case保留，Record/File值错误明确Equatable/Sendable。AudioCache私有接纳只翻译／抛错，公开begin/register等操作报告一次；回归验证关闭后两次拒绝只得到各自公开操作的两条报告，未执行取消回调，原closed错误仍抛出。
- ✅ Hub下载复用单次读取／解码的计划快照，保留原ID/revision/endpoint选择、实际网络元数据流程及旧暂存完整文件迁移。离线完整计划／文件恢复通过；没有删除有效的内存存储、兼容迁移或有用途的SDK能力。
- ✅ PlatformKit根及Audio/Vision声明／导入统一；相关README收口当前协议、生命周期和错误契约，移除预热／游标的过时描述。更正工程README把CurrentChatCapability误记为App源码的说明，实际仍由ModelKitRuntime唯一编译。ModelKitDefaults进程级管理器未迁移为App根，作为独立缺口保留。
- ✅ 最终基础库源码边界／端口／退役接口及错误归属守卫通过：`/tmp/mobileharness-foundation-boundaries-final.log`。三个基础模块的严格格式通过（`/tmp/mobileharness-foundation-format.log`为空）；工程／隐私／权限plutil、git diff --check及所有相关README路径通过。
- ❌ 初次完整检查新增回归遗漏CacheContainer.audioScope的await，导致测试编译失败，已修正；保留`/tmp/mobileharness-foundation-check.log`。
- ✅ 最终完整检查静态边界、六项Python回归、严格格式和AppWorkflow116项通过；两项新增事件／错误报告回归均通过。
- ❌ 最终完整检查未通过：UITests83项中cameraNativeMetalDrawStopAndLayerHandoff超时；Integration999项中11项失败、19个问题，为nexArmIntermediateTimeoutAdvancesAndReportsMissingSegmentAfterEnding、uiFullHomeOwnsToastExpiryWithoutAViewAndStopJoinsEffects、atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、七项soundSource及visionRejectsMismatchedCaptureBeforeCallingModel。日志`/tmp/mobileharness-foundation-check-final.log`；未将其认定为全部环境问题或清理无关问题。
- ✅ 定向运行119项，其中117通过、2跳过：ModelKit Core/Runtime/Defaults/Hub和43项原生输入／容器／Storage集成，日志`/tmp/mobileharness-foundation-targeted.log`。跳过的是需要真实YOLO归档的productionYOLOArchiveInstallsWithNativeExtractor和需要外部端点的liveHubDownloadPublishesFilesAndIntermediateProgress，不记为硬件／网络通过。
- ✅ 最终签名真机构建通过：`/tmp/mobileharness-foundation-device-final.log`；早期未含全部反馈端口的构建另存`/tmp/mobileharness-foundation-device.log`，不替代最终结果。
- ❌ Simulator仍被CoreAIShared无法解析CoreAI依赖阻断，后续scheme未执行：`/tmp/mobileharness-foundation-simulator.log`。
- 本轮未重新安装或进行音频／触觉／相机／串口实际设备验收，没有真实模型稳定性或帧率通过结论。工作区既有修改保持，无新目录／编译目标／依赖，未提交。

### UI 并发开销与渲染清理（2026-10-18）

实现：光环线程句柄／退出标记由锁保护，RunLoop明确停止，等待真实GPU完成后归还三个槽位，并发出清理完成屏障；视频／骨架各复用一个可续期任务，延后期限不创建新任务，更早期限取消并加入旧等待；到期闭包不持有像素帧。频谱固定颜色、边框和布局按配置／尺寸缓存。保留两个显示线程及帧率，不新增目录／依赖，未提交。

- ✅ 到期定向6项通过，含4项新增回归（续期、更早期限、清屏后重启、所有者释放）及既有独立姿态／视频到期：`/tmp/mobileharness-ui-concurrency-targeted.log`。
- ✅ UI根8项定向通过：`/tmp/mobileharness-ui-concurrency-ui.log`；该次UI目标整体仍失败，87项中1项cameraNativeMetalDrawStopAndLayerHandoff超时，不记为全量UI通过。
- ❌ 完整检查未通过：UI87项中上述1项失败；Integration999项中8项失败、15个问题（uiFullHomeOwnsToastExpiryWithoutAViewAndStopJoinsEffects及七项soundSource）。AppWorkflow116项通过；源码边界、严格格式及Python6项通过。证据`/tmp/mobileharness-ui-concurrency-check.log`。单跑根测试通过不覆盖全量失败，不认定均为环境问题。
- ✅ 最终签名真机构建通过：`/tmp/mobileharness-ui-concurrency-device-final.log`。首次构建因HaloControl含非Sendable的Thread句柄失败，见`/tmp/mobileharness-ui-concurrency-device.log`；已按相机同类契约限定为锁保护的unchecked Sendable并重建通过。
- ❌ Simulator因CoreAIShared无法解析CoreAI依赖失败，后续scheme未运行：`/tmp/mobileharness-ui-concurrency-simulator.log`。
- ✅ 最终源码归属／依赖边界复查：`/tmp/mobileharness-ui-concurrency-boundaries.log`；受影响Swift文件严格格式、项目／权限plist及git diff --check通过。
- ❌ iOS专用光环重复停止／无帧退出／释放用例已编写，但本轮未在iOS测试运行器执行；签名App构建不代表测试已编译或执行。带在途GPU帧的光环停止仍需设备回归。
- ❌ iPhone17Pro显示unavailable，未安装／启动本轮构建：`/tmp/mobileharness-ui-concurrency-devices.log`。本轮无真实线程数、内存、功耗、回复开头视频流畅度或真实YOLO稳定性通过结论。

### UI并发修复版安装与提交基线（2026-10-18）

用户要求先安装测试、提交当前修改，再进行UI并发审查列出的优化。已将签名构建安装到iPhone17Pro并启动，安装序号3972；日志`/tmp/mobileharness-ui-concurrency-install.log`和`/tmp/mobileharness-ui-concurrency-launch.log`。此安装补充此前设备不可连接的限制，不覆盖之前自动化失败，也不代表用户手工、功耗或模型稳定性验收通过。后续优化另行记录，不混入这次已安装版本。

### UI并发审查后续优化（2026-10-18）

从已安装3972的提交b846d32开始修改，手机基线不变。待验证：光环失败锁存／去重、历史读取生命周期／异步目录／时间线缓存、资源恢复与防抖保存归属。计划运行针对回归、完整检查、Simulator和签名构建；字幕／图片、日志和实际功耗等待独立测量，后续修改不自动提交。

真机基线3972用户反馈：展示没有报错和明显异常。此为当前操作范围内的手工反馈，不延伸为长时间YOLO稳定性、实测内存／功耗或后续未安装修改的验收。

本批实现与最终验证：

- ✅ 光环使用生产HaloRenderState锁存失败，只报告首次真实失败，拒绝后续输入；相同快照不唤醒、刷新率只在阶段／配置变化时提交。保持两个显示线程和GPU槽位真实回收，不改变帧率。
- ✅ 历史消息读取由页面拥有，一个实际读取＋一个最新候选，取消清空候选并撤销回执；旧读取退出后才开始候选，避免取消任务链积累。目录按JSON身份保留结果，在通用执行器解析；时间线仅随会话／分页变化异步重建并预分组，不由body反复投影。
- ✅ 下载源编辑通过控制接口更新；ModelResourceInteractionWorkflow合并初始恢复并拥有一个可续期防抖任务，忙碌完成驱动续存，不轮询、不重放失败保存。已恢复页面不覆盖端点草稿；偏好失败仍允许显式restore重试。ApplicationFeatures停止执行依赖前取消并加入恢复／防抖任务。
- ✅ 定向9项通过（4项UI、5项应用工作流，其中含既有偏好重试回归）：`/tmp/mobileharness-ui-review-regression-latest.log`。此前`/tmp/mobileharness-ui-review-targeted.log`暴露显式偏好恢复重试被跳过，已保留该语义修复；`/tmp/mobileharness-ui-review-regression.log`曾因Testing宏内直接调用mutating方法编译失败，已将调用结果分离后重测。
- ✅ 最终完整检查中UI91项及AppWorkflow120项通过，含相机原生Metal启停／交接；源码归属、依赖边界、严格Swift格式与Python6项通过。证据`/tmp/mobileharness-ui-review-check-final.log`。先前Metal回归曾超时，单次通过不代表已证明长期稳定。
- ❌ 完整检查整体未通过：Integration999项中9项失败、17个问题，为atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、七项soundSource及visionRejectsMismatchedCaptureBeforeCallingModel；不归因为全部环境问题。较早一轮结果保留在`/tmp/mobileharness-ui-review-check.log`，不覆盖最终结果。
- ✅ 最终签名真机构建通过：`/tmp/mobileharness-ui-review-device-final.log`。早期构建也通过，见`/tmp/mobileharness-ui-review-device.log`，最终结果包含历史读取容量限制的最后修订。
- ❌ Simulator仍被CoreAIShared无法解析CoreAI依赖阻断，后续scheme未执行：`/tmp/mobileharness-ui-review-simulator.log`。
- 本批未安装、未提交；手机保留用户已反馈正常的3972／b846d32基线。新增GPU故障行为仅由生产接纳状态测试覆盖，未进行真实GPU故障注入或本批原生iOS动画、模型稳定性、功耗／内存／帧率验收。字幕／图片准备／空闲日志刷新未调整，等待采样证据。

### UI并发优化版真机安装（2026-10-18）

按用户要求将当前未提交优化版安装并启动于iPhone17Pro，安装序号3980。使用最终签名构建，确认改动中的构建输入均不晚于可执行文件；安装日志`/tmp/mobileharness-ui-review-install.log`，启动日志`/tmp/mobileharness-ui-review-launch.log`。已替换此前3972基线；包含光环失败锁存／去重、历史读取与投影缓存、资源恢复／防抖保存优化，字幕合并与排版尚未调整。安装和启动成功不代表本版手工、模型或性能验收通过，源码仍未提交。

### 关闭聆听时 missingAudio 调查（2026-10-18）

用户截图在17:39显示同一会话的 `storage.cache.audio` / `cancel: missingAudio` 和 `fail: missingAudio`，补充操作“关闭聆听好像”。本轮仅分析，未修改运行代码、重新安装或重启应用。

- ✅ 只读访问连接的 iPhone17Pro，确认安装的应用为 `dev.mobileharness.app`。复制应用 records.sqlite 与 WAL 至本机临时文件，副本 quick_check 为 ok；17:39:47 创建的最后一轮 assistant 消息为 cancelled，原因为 `CancellationError()`。数据库没有截图会话ID或这两条容器异常，故只作为同时间取消的旁证，不能宣称从持久化数据恢复了截图的完整事件顺序。副本未纳入仓库，也未读取配置凭据或下载用户媒体。
- ✅ 当前源码（调查基线 `9426eb47`）明确存在竞态：VoiceSessionCoordinator.cancelReplyWork 并行执行会话音频清理与 runtime.cancelReply；前者删除句柄并忘记取消终态。SpeechPlayback 的 onCancel 随后按ID取消已清理句柄，AudioCache 报 cancel/missingAudio；catch 再调用 fail，同一错误又报告一次。AudioCache.fail 在检查句柄是否存在之前报告，因此第二条不代表发生第二次音频生产故障。
- ✅ 使用未修改的 StorageCore、StorageCache、FunctionContracts 及 SpeechPlayback 生产源码单独编译本机诊断程序。正常读完成功且零报告；先取消播放返回 CancellationError 且零报告；先清理会话或输入、再取消播放，均返回 CancellationError 并且恰好报告 `cache.audio cancel: missingAudio`、`cache.audio fail: missingAudio`。程序 `/tmp/mobileharness-missing-audio-repro.swift`，输出 `/tmp/mobileharness-missing-audio-repro.log`。这是受控任务顺序与合成PCM验证，未执行真实TTS或原生播放器。
- ❌ 取消清理竞态及重复报告尚未修复。建议在已取得所有权的播放租约上提供可加入、幂等的终止，并使作用域清理加入消费者取消后再回收终态；保持未知句柄、越权、实际读写和生产失败的明确错误，不全局过滤 missingAudio。
- 未运行完整检查或iOS构建：本轮没有运行代码变更，仅补充调查证据；未完成修复后的真机关闭聆听验收，亦未由本次调查推断相机卡顿或模型稳定性结论。

### 原生TextRenderer字幕试用（2026-10-18）

从9426eb47干净工作区开始，待实施：单Text／TextRenderer替换双UILabel，按单调出生时间处理新增淡入并保留滚动、Unicode、定稿、Reduce Motion和失活语义。计划状态／离屏原生测试、完整检查、Simulator和签名构建；真机视觉／性能独立记录，不预设比旧实现快。

本轮实际结果：

- ✅ 一个SwiftUI Text＋TextRenderer替换双UILabel／NSMutableAttributedString；按相邻单调出生时间合并run，文字在TimelineView tick闭包外构造。最多保存320个字素；相同追加字符、窗口移位和组合字符延长均保留正确边界与旧淡入进度。定稿／Reduce Motion／失活结束动画，不创建逐字Task、线程或应用定时器；动画节奏不快于60Hz，视频／光环刷新策略未变。
- ✅ 定向18项通过：UI12项、1项字幕Tool集成、5项应用会话回归，日志`/tmp/mobileharness-text-renderer-regression.log`。新增5项测试覆盖进度、窗口与相同字符、组合字符修订、结束／清空，以及生产TextRenderer的原生离屏像素；实际验证已有A字形区域不变、新增B透明度随时间增加、强制可见等于最终结果。离屏ImageRenderer不是原生滚动／上屏帧率验收。
- ✅ 完整检查中UI96项（含原生字幕像素及相机Metal启停／交接）、AppWorkflow120项通过；源码边界、README归属、严格格式及Python6项通过：`/tmp/mobileharness-text-renderer-check.log`。
- ❌ 完整检查整体未通过：Integration999项中12项失败、21个问题，为uiFullHomeOwnsToastExpiryWithoutAViewAndStopJoinsEffects、atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、原七项soundSource、mediaTransportSurvivesExpiryDuringDispatchAndDisplaysNextFrame、visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers及soundSourceContextWriteFailureReportsWithoutStoppingOrSelfJoin。不将其全部归为环境因素，也不覆盖历史失败。
- ❌ Simulator仍被CoreAIShared无法解析CoreAI依赖阻断，后续scheme未执行：`/tmp/mobileharness-text-renderer-simulator.log`。
- ✅ 签名真机构建成功：`/tmp/mobileharness-text-renderer-device.log`。已安装并启动iPhone17Pro，安装序号3988：`/tmp/mobileharness-text-renderer-install.log`、`/tmp/mobileharness-text-renderer-launch.log`。已请求用户验证相机并行回复时的淡入、长文本换行／滚底和前后台。
- ✅ git diff --check通过；源码中已无NativeCaptionSurface、CaptionSurface、UILabel或NSMutableAttributedString字幕路径。无新目录／编译目标／第三方依赖，未提交。
- ✅ 真机手工反馈：用户按上述3988版检查请求回复“没有，挺正常的”，本次测试未报告缺字、闪烁、滚动异常或视频卡顿。仅作为该次操作范围内的视觉／交互反馈，不扩展为长期模型稳定性结论。
- ❌ 尚无完整Instruments对照、内存／功耗／P95排版耗时或持续模型帧率结果，不认定性能已经优于3980双标签版。


## 2026-10-18 首页相机与深层历史聆听修复

已实现：导航覆盖首页时暂停相机捕获／姿态，保留开启意图，返回按原意图恢复；App 前后台变化也重新校验首页路径。Assistant 历史 prepare 移除误用的 beginSettingsChange/endSettingsChange（前者会调用 stopVoice），只检查取消并获取运行时；真实设置变更与 App 后台语音停机保持。

- 源码回归：检查历史绑定不得停止语音，导航不得全局失活，并要求场景／导航均更新相机准入；严格格式、边界及 Python 6 项通过。
- `./scripts/check.sh` 全量失败：UI 96、AppWorkflow 120 通过；Integration 999 项中有 11 项失败、20 issues，包含声源感知、机械臂截止时间、媒体过期和视觉统计，不能记为全量通过。日志 `/tmp/mobileharness-home-navigation-check.log`。
- 单独回归 5 项通过：原生常驻首页深层导航／根销毁，以及历史分页、刷新、取消与迟到返回；这是 macOS 原生视图和替身工作流证据，不证明 iOS 摄像／收音连续性。日志 `/tmp/mobileharness-home-navigation-regression.log`。
- `./scripts/build-ios.sh` 失败于 Simulator CoreAIShared 无法解析 CoreAI，后续 scheme 未执行。日志 `/tmp/mobileharness-home-navigation-simulator.log`。
- 签名真机构建通过，已安装到连接的 iPhone 17 Pro（安装序号4020）并成功启动。日志 `/tmp/mobileharness-home-navigation-device.log`、`/tmp/mobileharness-home-navigation-install.log`。
- ✅ 用户在安装序号4020的真机上按上述导航路径复测，反馈“是的，没问题”：深层导航期间聆听保持，相机离开首页暂停、返回恢复，原本关闭的相机不会自动开启。此结论为用户交互验收，不代表持续性能或真实模型稳定性已量化。
- ❌ 非首页切 App 后台再返回、快速进出及启停期间导航的组合场景尚未单独确认；不扩大本次用户反馈的验收范围。

### 关闭聆听的音频清理顺序修复（2026-10-18）

用户明确要求最后清理音频，至少等待取消播放。已先更新总体、Agents／Support 和 IntegrationTests README，再修改实现；保留工作区既有字幕／导航改动，不新增目录、目标或依赖。

- ✅ VoiceSessionCoordinator.cancelReplyWork 移除并行 cancelSpeechAudio 分支，使用同文件的 VoiceReplyCancellation 依次加入 runtime.cancelReply（已接纳执行／播放取消）、audio.waitForPlaybackStop、会话音频清理。stopVoice 的即时原生停声保持；顺序器不创建额外任务／队列。中断失败或取消也执行后两阶段，随后向原提示路径传播原错误；没有过滤 missingAudio 或修改 Storage 的失败语义。
- ✅ 最终定向6项测试通过，新增参数化回归含正常返回／失败／取消三种情况。使用真实 AudioCache／SpeechPlayback、合成PCM及显式退出 gate，验证播放任务退出前、原生停止加入前均保留排队音频，最后清理无容器故障，且错误身份保留；同时验证正常释放、真正缺失仍上报、所有权／容量、按来源取消、公开接纳失败报告及回复结束加入。日志 `/tmp/mobileharness-audio-stop-order-related.log`。原生停止与PCM来源为替身，不代表真实模型或iOS播放器验收。
- ✅ 签名真机构建通过：`/tmp/mobileharness-audio-stop-order-device.log`；本轮未安装、重启或操作真机。
- ❌ `./scripts/build-ios.sh` 在首个 Simulator scheme 的 CoreAIShared 无法解析 CoreAI 处失败，后续scheme未执行：`/tmp/mobileharness-audio-stop-order-simulator.log`。
- ✅ 完整检查中的模块边界／源码归属／README、严格Swift格式、Python6项及AppWorkflow120项通过，新增顺序回归的三种参数均通过；另行 git diff --check、修改文件严格格式与工程／隐私／权限plutil通过。
- ❌ 完整检查整体未通过：UI96项中cameraPoseExpiresWithoutRemovingLiveVideo失败；Integration1000项中10项失败、22个问题，为atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、七项soundSource、visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers、visionResolvesOpaqueInputWithoutCopyingMediaIntoObservation。日志 `/tmp/mobileharness-audio-stop-order-check.log`；未证明这些失败都是环境问题，不将定向通过替代全量通过。
- ❌ 修复后的真机关闭聆听、快速启停及前后台验收仍待执行，不将本机替身测试或编译视为真机通过。字幕／导航等既有改动不纳入本次音频修复提交。

### 资源操作未使用刷新代次返回值（2026-10-18）

先更新 ApplicationControl README，再将 ModelResourceInteractionWorkflow.perform 中仅用于失效旧刷新的调用改为 `_ = state.beginRefresh()`；不改变返回值接口、刷新代次或业务行为，不新增测试、目录或依赖。

- ✅ 完整检查重新编译后未再出现 beginRefresh 未使用返回值警告；模块边界、README、严格格式、Python6项、UI96项及AppWorkflow120项通过。另行修改文件格式、git diff --check及工程／隐私／权限plutil通过。
- ❌ 完整检查仍未通过：Integration1000项中12项失败、22个问题，涉及atomic稳定离靶、七项soundSource、媒体到期传输、Vision预算恢复、soundSourceContextWriteFailureReportsWithoutStoppingOrSelfJoin及Vision不复制媒体。日志 `/tmp/mobileharness-unused-refresh-check.log`；不将这些失败全部归因于环境。
- ❌ `./scripts/build-ios.sh` 仍在首个Simulator scheme的CoreAIShared无法解析CoreAI处失败，后续scheme未执行：`/tmp/mobileharness-unused-refresh-simulator.log`。本轮未另行签名构建、安装或操作真机，未提交。

## 2026-10-19 ModelKit 容器化

已实现于 codex/storage-lifecycle-boundary，基线6431d36f；main-sh仍为377b5470，未合并或修改。ModelContainer 持有 language／speech／vision／artifacts，同根注册、实例私有 manager／选择配置，业务消费者注入窄端口。后台关闭接纳、取消加入并保留已加载权重；根停止先加入推理、关闭制品，再释放 manager 注册／配置。生产静态 Defaults 和旧 CurrentChatCapability 已移除。后台回调复用同根制品准备，冷启动准备在作用域替换时也有明确清理。

- ✅ 首轮模型与注册定向回归5项通过，包括流失败早／晚观察一次、暂停取消加入与权重保留、默认根隔离／关闭、App四子能力共享。第二轮增加聊天配置隔离／保留端口更新及不合作加载的迟到等待者，相关结果见最新日志；测试不申请权限、不运行真实权重或联网。
- ✅ 第一轮签名构建通过：`/tmp/mobileharness-model-container-device.log`。后续清理曾出现局部变量 assembly 遮蔽导致编译失败，已改为 self.assembly；最终结果另记，不以第一轮替代最终构建。
- ❌ Simulator 首个scheme仍被CoreAIShared无法解析CoreAI阻断，后续scheme未执行：`/tmp/mobileharness-model-container-simulator.log`。
- ❌ 第一轮完整检查未通过：UI和Integration存在超时／状态失败（Integration1001项、41 issues），模型新增回归均通过，不能归为全部环境问题。日志 `/tmp/mobileharness-model-container-check.log`；最终检查另记。
- ✅ 最终模型相关定向93项通过（SDK模型／资源／制品、根与配置、流故障观察及App注册）：`/tmp/mobileharness-model-container-api-regression.log`。语言／视觉控制统一为 load/warmup/unload/status；语音按类别控制，状态读取选择后的实际后端，卸载覆盖同类本地和系统提供者。默认根测试另断言元数据查询不加载权重。
- ✅ 最终签名构建通过：`/tmp/mobileharness-model-container-delivery-device.log`。工程／隐私／权限plutil、git diff --check、最终25项Skill资源与函数声明打包检查通过：`/tmp/mobileharness-model-container-resources.log`。
- ❌ 最终完整检查整体未通过：UI96项中cameraNativeMetalDrawStopAndLayerHandoff失败；Integration1001项中10项失败、21 issues，为uiFullHomeOwnsToastExpiryWithoutAViewAndStopJoinsEffects、atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、七项soundSource及visionResolvesOpaqueInputWithoutCopyingMediaIntoObservation。AppWorkflow120项、模型相关及新增回归、源码边界、严格格式和Python6项通过。日志 `/tmp/mobileharness-model-container-delivery-check.log`；未证明这些失败全部属于环境，不把定向通过替代全量通过。
- ✅ 真机最初不可连接，安装尝试被CoreDevice4016拒绝；连接恢复后，最终版本已安装到iPhone17Pro，安装序号4124：`/tmp/mobileharness-model-container-install-final.log`。启动被锁屏拒绝（Locked），未确认应用已运行：`/tmp/mobileharness-model-container-launch.log`。
- ❌ 实际聊天／连续聆听与合成、姿态、模型配置／资源、前后台权重复用、旧任务不重放及后台下载恢复的真机验收待用户反馈；不以替身、元数据或编译证明模型稳定性。本轮未提交。

- ✅ 2026-10-19 按用户要求重新安装同一签名产物（确认无更新的Swift源码），iPhone17Pro安装序号4132，成功启动。日志 `/tmp/mobileharness-model-container-reinstall.log`、`/tmp/mobileharness-model-container-relaunch.log`。仅确认安装／启动，真实模型及交互验收仍待反馈。

## 2026-10-19 模型真机反馈与本地窗口兼容

✅ 用户确认已测试语音识别／合成的Apple原生和开源模型，以及云端大模型，均无问题。仅记录这些场景，不扩展为持续功耗／后台下载／本地LLM通过。

❌ 本地LLM真实推理尚未通过验收；已实现ModelKit内的4096总窗口适配，最新5条消息含当前输入，裁剪system并为生成留空间。定向、完整检查、Simulator、签名构建与真机结果分别记录。

已实现 GemmaContextBudget：最新5条非system消息包含当前输入，必要时裁剪system及最旧历史；实际完整模板token与生成上限合计不超过4096，Engine入口再次检查。默认先预留1024，拟合后未指定输出上限的请求仍按原规则使用剩余窗口。

定向13项通过（输出预算另含6组参数），1项真实权重用例按未启用标记跳过；覆盖Unicode、原请求不变、模板／输出预算、非单调计数、取消，以及旧历史不支持的输入仍拒绝。计数器为替身，不代表真实本地模型效果。日志 `/tmp/mobileharness-gemma-window-final.log`。

- ✅ 定向最终13项通过、1项真实权重测试跳过；完整检查中Gemma同组结果一致，UI96和AppWorkflow120项通过，源码归属／模块独立、严格格式、Python6项通过。
- ❌ `./scripts/check.sh` 整体失败：Integration1001项中10项失败、18 issues，为atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、bluetoothLateNativeAimErrorIsReportedAfterRecoveryFencesTheConnection、七项soundSource及visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers。日志 `/tmp/mobileharness-gemma-window-check.log`，不将失败全部归因于环境。
- ❌ `./scripts/build-ios.sh` 首个Simulator scheme被CoreAIShared无法解析CoreAI阻断，后续scheme未执行：`/tmp/mobileharness-gemma-window-simulator.log`。
- ✅ 签名真机构建成功：`/tmp/mobileharness-gemma-window-device.log`；工程／隐私／权限plutil、最终Skill／函数资源验证及git diff --check通过，资源日志 `/tmp/mobileharness-gemma-window-resources.log`。
- ✅ 修复版已安装iPhone17Pro（安装序号4140）；首次启动遇到CoreDevice远程连接错误，重试后成功启动。日志 `/tmp/mobileharness-gemma-window-install.log`、`/tmp/mobileharness-gemma-window-launch-retry.log`。
- ❌ 本地Gemma真实tokenizer／CoreAI连续回复、实际业务长system及20轮历史验收待用户反馈；权重无关计数器回归不代替真实模型效果。不修改Agent、云端请求或持久历史，保留既有模型容器改造及全部工作区修改，未提交。

### 本地 Gemma 原始消息校验修复（2026-10-19）

用户真机反馈旧的笼统 invalidRequest，真实模型尚未通过验收。源码确认历史请求可产出空assistant，旧Gemma全量非空校验会拒绝。计划仅在ModelKit规范化推理副本：移除空历史、归并system，保留当前输入身份与4096预算，补充针对性回归；具体真机触发分支尚未由日志确认。

已实现上述ModelKit内规范化，并将旧笼统报错拆为源请求大小、末尾非system角色、空当前输入三个原因；错误不含消息正文。定向测试 `/tmp/mobileharness-gemma-validation-test.log`：16项通过，真实权重测试1项跳过（框架汇总17项）。真实Gemma仍待用户复测。

验证与交付：

- `/tmp/mobileharness-gemma-validation-check.log`：静态依赖检查、格式、Python 6项、UI 96项、AppWorkflow 120项通过；Gemma 16项通过、真实权重1项跳过。完整检查退出1：Integration 1001项中9项失败、16个issue（首页Toast到期、7项soundSource、mediaTransport到期派发）。这些失败未作为通过或已排除回归记录。
- `/tmp/mobileharness-gemma-validation-simulator.log`：模拟器构建退出65，CoreAIShared无法解析CoreAI；后续scheme未执行。
- `/tmp/mobileharness-gemma-validation-device.log`：签名真机构建成功；25项最终应用资源检查、project/privacy/entitlements及diff格式检查通过。
- `/tmp/mobileharness-gemma-validation-install.log`、`/tmp/mobileharness-gemma-validation-launch.log`：已安装到iPhone 17 Pro（安装序列4148）并启动。原生Gemma生成、长历史与4096边界验收尚待用户复测，自动化计数器不能代替真实模型验收。
- 本轮未自动提交；工作仍在codex/storage-lifecycle-boundary，未修改main-sh。

### CoreAI iOS有效窗口修复（2026-10-19）

用户反馈contextLengthExceeded(0, 1024)。已定位固定依赖CoreAIPipelinedEngine.runCompletion的iOS GrowingKVCache 1024保护（源码引用apple/coreai-models#124），不是4096总预算校验失效；ModelKit未纳入实际更小后端限制。计划统一引擎配置与推理预算使用有效窗口，保留上游安全限制，不修改依赖和Agent，补充小窗口回归。真实模型仍未通过。

已实现统一后端有效限额：iOS取min(1024, 模型声明)，macOS取min(4096, 模型声明)，引擎配置、实际token拟合及生成防御校验同源；默认预留min(1024, 窗口/4)，最终输出不超过剩余窗口。未绕过依赖保护、未修改Agent或三方源码。该更小上下文可能减少可保留历史及system内容；真实回复质量和长度待测。

- `/tmp/mobileharness-gemma-backend-window-test.log`：20项定向测试通过、真实权重1项跳过（框架汇总21项）；新增有效容量解析、1024下长system／20轮历史／显式输出上限、当前输入超限与非法容量回归。
- `/tmp/mobileharness-gemma-backend-window-check.log`：静态、格式、Python 6项、UI 96项、AppWorkflow 120项通过；完整检查退出1，Integration 1001项中10项失败、19个issue（bluetoothLateNativeAim、8项soundSource、visionDiscardsOverBudget）。未证明这些失败与本次无关，不记为全量通过。
- `/tmp/mobileharness-gemma-backend-window-simulator.log`：退出65，CoreAIShared无法解析CoreAI，后续scheme未执行。
- `/tmp/mobileharness-gemma-backend-window-device.log`：签名真机构建成功；25项最终资源、project/privacy/entitlements及diff格式检查通过。
- `/tmp/mobileharness-gemma-backend-window-install.log`、`/tmp/mobileharness-gemma-backend-window-launch.log`：iPhone 17 Pro安装序列4156，启动成功。真实Gemma输出、长历史与实际窗口稳定性待用户复测。未自动提交，未修改main-sh。

### Gemma无system排查版本（2026-10-19）

用户要求先移除全部system再测，尚未确认1024版本的具体失败或输出表现。计划删除本地推理副本system及不再使用的拟合实现，保留对话和窗口防御；原请求和云端不变。此版本不代表system指令或完整Agent业务验收。

已实现：本地Gemma从推理副本移除全部system，删除不再使用的system截短／二分拟合算法；最多5条非空对话消息包含完整当前输入，继续以实际token计数遵守iOS 1024上限。原请求、持久历史与云端未改变；失去system指令属于本次用户指定的排查行为，不代表完整Agent业务验收。

- `/tmp/mobileharness-gemma-no-system-test.log`：19项定向测试通过、真实权重1项跳过（框架汇总20项）。验证首部／中间／末尾／Unicode超长system不进入任何tokenize调用；保留原请求和当前输入、输出上限及取消回归。移除已删除二分算法的非单调计数测试。
- `/tmp/mobileharness-gemma-no-system-check.log`：静态、格式、Python 6项、UI 96项、AppWorkflow 120项通过；完整检查退出1，Integration 1001项中11项失败、22个issue：首页Toast到期、atomicStableOffTarget、7项soundSource、mediaTransport到期派发及visionOpaqueInput。未将失败记为通过，未证明与本次无关。
- `/tmp/mobileharness-gemma-no-system-simulator.log`：退出65，CoreAIShared无法解析CoreAI；后续scheme未执行。
- `/tmp/mobileharness-gemma-no-system-device.log`：签名真机构建成功；最终25项资源检查、project/privacy/entitlements及diff格式通过。
- `/tmp/mobileharness-gemma-no-system-install.log`、`/tmp/mobileharness-gemma-no-system-launch.log`：iPhone 17 Pro安装序列4164，启动成功。真实生成及原会话连续对话待用户复测；未自动提交，main-sh未修改。

### 无system版真机反馈与性能排查（2026-10-19）

用户确认本地Gemma可以生成，但可见首token需等待几十秒，且按住开启聆听会卡顿。此反馈只确认基础生成可用，不代表性能或完整Agent行为通过。

源码检查：GemmaLanguageEngine与Gemma4Chat为actor；S=1图要求COREAI_CHUNK_THRESHOLD=1，每轮显式重置缓存；thought内容生成后被过滤。ModelResource.release仅释放租约，releaseWhenIdle只在内存压力回收路径生效，不能据此断言每轮都卸载权重。聆听按住路径在MainActor准备触觉、异步准备提示音，尚无调用栈证据说明卡顿来自主线程、GPU竞争或内存压力。未据猜测新增线程或改写缓存策略。

尝试Time Profiler附加进程未成功（找不到进程）；重启应用成功后，全进程采集 `/tmp/mobileharness-gemma-listening-20261019d.trace` 在1.851秒因Device disconnected中止，未采到用户复现，不能作为性能结论。日志 `/tmp/mobileharness-gemma-listening-profile.log`；目录 `/tmp/mobileharness-gemma-listening-profile-toc.xml`。已请求用户连接数据线、保持解锁并打开应用，等待重新采样。此阶段未修改代码，未运行构建或测试，未提交。

### Gemma／聆听性能复采与修复计划（2026-10-19）

用户确认复现，Time Profiler成功采集55.841秒：`/tmp/mobileharness-gemma-listening-retry-20261019.trace`（日志／TOC／samples／hangs／analysis同前缀）。导出时工具警告localspeechrecognition镜像地址重叠，结果仍可读，保留符号化限制。主线程potential-hangs记录40.443秒开始的980.715ms卡顿；附近采样含AVAudioSession.privateSetActive和SpatialAudioCapture.init→AVCaptureSession.init→同步XPC。Gemma引擎加载采样始于49.14秒，持续到54.39秒，采集末端未覆盖可见输出，无法据此量化完整TTFT或断言模型导致此卡顿。

资源清单轮询installed相关包容采样约4487ms（不是墙钟延迟），路径校验约1892ms，其中逐字符CharacterSet.union反复分配明显。计划缓存字符集；本次不缓存磁盘安装结论，不改变完整性校验。录音启动会话配置移至已有原生actor并加入单一准备任务，空间会话惰性创建；模型补充加载／首原生token／首可见文字signpost以继续采样。

实施及自动化结果：

- SpatialAudioCapture只在actor的start且确认FOA支持后构造AVCaptureSession，stop不再为未启动后端创建会话。AppleAudioIO通过既有NativePlaybackGraph配置共享会话；单个capturePreparation Task由token拥有，父取消转发，stopCapture先关闭接纳再取消并加入准备；迟到启动失败不关闭新token会话。单声道引擎其余启动及会话deactivate路径未在本轮迁移，不能声称所有音频同步调用都已移出主线程。
- ModelArtifactCatalog静态缓存不可变CharacterSet，保留Unicode／标点／路径拒绝规则；未缓存安装事实，清单双重磁盘检查仍保留。
- Gemma signpost：EngineLoad、Generation及FirstNativeToken／FirstVisibleText，只有token数量元数据，不含正文。尚未用新版本量化冷加载／预填充／隐藏thought的占比，不宣称首token改善。
- `/tmp/mobileharness-gemma-listening-fix-tests.log`：22项定向测试通过（2项目录规则、6项录音就绪、14项窗口回归），不包含真实模型测试。录音原生配置任务的iOS行为仅构建和静态归属检查，仍需硬件复验。
- `/tmp/mobileharness-gemma-listening-fix-check.log`：系统OSLog白名单初次检查未通过，补充明确系统依赖文档及白名单后重跑；静态／格式／Python 6项、UI 96项、AppWorkflow 120项通过。最终完整检查退出1：Integration 1001项中12项失败、21个issue（Toast到期、atomicStableOffTarget、8项soundSource、mediaTransport到期及visionDiscardsOverBudget）。不记为全量通过，未证明失败与本次无关。
- `/tmp/mobileharness-gemma-listening-fix-simulator.log`：CoreAIShared解析CoreAI失败，退出65；后续scheme未执行。`/tmp/mobileharness-gemma-listening-fix-device.log`：签名真机构建通过；25项应用资源、project/privacy/entitlements和diff检查通过。
- `/tmp/mobileharness-gemma-listening-fix-install.log`：iPhone 17 Pro安装序列4188成功；`/tmp/mobileharness-gemma-listening-fix-launch.log`：锁屏拒绝启动。已请求解锁，再开始长时间性能采样；修复效果及真实模型性能尚待复验。未提交，未修改main-sh。

### 首页模型准备门禁（2026-10-19）

用户要求按已讨论设计实施。计划App持有串行可取消准备，UI独立呈现，当前模型按状态跳过／准备，云端不自动生成探测，保留设置与已有停止。不改制品下载策略、不自动提交。

实施结果：

- App的Services持有唯一ForegroundPreparation，并以homePreparation服务加入native之后的生命周期；模型／UI已开放前台接纳后才激活，失活同步取消本次结果接纳，停止先加入准备worker再关闭模型。任务不由页面task拥有，一个worker＋一个待重检位，旧配置／页面代际结果不可放行；原生不合作工作仍须真实退出，不承诺取消立即停机。
- 首页初次进入、导航返回、Scene恢复、Provider／语音配置应用、相机启用状态变化触发检查。当前language／recognition／synthesis／VAD依次按状态跳过或warmup，相机启用时vision按需load；不加载其他已安装模型，不新增云端探测请求。全部结束后再复查，避免后续加载回收了前面的模型仍错误放行。云端只表示本地客户端配置／资源就绪，不保证远端凭据、网络或服务可用。
- UI.home持有独立HomeModelPreparation，保留voicePhase和原会话；加载眼睛复用NativeCompanionSurface，不新增Canvas或线程。新聆听／新开相机／切镜头受门禁，设置、取消／重试及已有会话／相机关闭入口保留。活动会话存在且能力尚冷时延后预热，活动结束重检；导航不关闭既有聆听。
- `/tmp/mobileharness-home-preparation-tests-delivery.log`：新增8项定向测试通过（6项任务编排、2项UI状态接纳），覆盖已就绪跳过、顺序、快速失活恢复、取消加入、失败重试、活动延后、100次配置刷新合并／旧选择围栏、加载后被回收的最终复查，以及旧UI根隔离。最后配置合并用例在全量检查编译后增加，已独立执行通过。
- `/tmp/mobileharness-home-preparation-check.log`：首轮UI98、AppWorkflow124通过；Integration1001中10项失败／19issues，退出1。`/tmp/mobileharness-home-preparation-check-final.log`：静态／格式／Python6、UI98、AppWorkflow125通过；Integration1001中17项失败／33issues，退出1。最终全量失败：nexArmPlaybackCongestion、homeToastExpiry、visionHealth、atomicStableOffTarget、8项soundSource、mediaTransportExpiry以及4项vision预算／统计／输入身份／opaque输入；不是全量通过，未证明与本次无关。
- `/tmp/mobileharness-home-preparation-simulator.log`：CoreAIShared无法解析CoreAI，退出65，后续scheme未执行。
- `/tmp/mobileharness-home-preparation-device.log`：首次签名构建失败，ProvidedCapability归属ModelKitRuntime，已修正App显式import。retry及最终 `/tmp/mobileharness-home-preparation-device-final.log` 签名构建通过；最终25项应用资源、project/privacy/entitlements及diff检查通过。
- `/tmp/mobileharness-home-preparation-install.log`：设备不可用，CoreDevice4016，安装失败，未启动本版；已请求重新连接和解锁。真实冷加载耗时、加载眼睛、云端客户端准备、取消／设置修复、深层聆听保持、相机及前后台／根重建验收均尚待真机。此前音频启动隔离和Gemma时序标记改动随构建保留，但性能改善仍未验收。
- 工作保持codex/storage-lifecycle-boundary；未修改main-sh，未自动提交，也未移除工作区既有改动。无新目录、编译目标或第三方依赖。

### 蓝牙连接条件与页面呈现（2026-10-19）

用户报告未连接机械臂触发基础模块Toast；计划保留Platform错误，仅在Agent归类为连接状态，经两个Action呈现。稳定条件代码归Gateway，原始记录保留，真实协议／发送／停止故障不隐藏。

实施结果：

- Platform抛错保持原样。Gateway.DeviceInputAdapter将connectivity.bluetooth的unavailable／unknownDevice／incompatibleService，以及连接／服务／特征／通知建立步骤的timeout/native失败编码为稳定bluetooth.*连接条件；ContainerFailureChannel保留原始错误详情和投递记录。发送阻塞、发送／响应步骤错误、协议损坏、断开未确认等继续为故障。
- ApplicationControl接纳连接条件为私有连接状态，不提交RuntimeDiagnostics异常列表／Toast。devices事实按availability／connection／recovery决策灰／闪蓝／蓝，迟到错误不覆盖已接收的实际设备状态；与模型无关。变更通过UI.BluetoothStatus.showBluetoothHome和showBluetoothSettings两项内部Tool呈现，沿用128在途上限和根身份／版本校验，呈现失败可观察且不递归Toast。
- ActionBindings.RuntimePresentation注入同根home和devices的UI自有BluetoothConnectionPresenting，UI保留独立revision且拒绝旧／停止端口；显示已连接不授予控制权限。蓝牙设置保留详细原生状态及运动策略，新增连接摘要。首页CAShapeLayer绘制图标，CABasicAnimation控制连接中闪烁，非连接中／减少动态／后台／视图移除时不保留闪烁；无新线程或逐帧Task。图标在灵动岛左侧，无灵动岛布局落安全区左上。
- 新增BluetoothStatusActions.swift位于既有Actions/UI目录，由原Actions目标自动编译；无新目录、编译目标或第三方依赖。状态函数独立于RuntimeDiagnostics故障组，不新增模型别名。
- 初次编译发现UI.BluetoothRecoveryStage没有rawValue，已按既有状态接口以String(describing:)提供事实。移动函数组后首次端到端测试因内部Tool路径使用展示title而非Swift函数名导致过期；已修正为完整生成路径，未扩大等待超时。静态检查拒绝在ContainerFailureChannel导入原生SDK，已把类型识别移入唯一原生适配文件DeviceInputAdapter，保留原依赖边界。
- `/tmp/mobileharness-bluetooth-status-regression.log`：7项定向回归通过，包含Gateway条件与严重故障区分、真实Gateway→Agent→两个Action→UI且不Toast／不记异常列表、迟到条件与重连／断开、冒充来源／旧根／未知参数／旧revision／停止根拒绝、显示不授权控制，以及全部角色目录完整性和既有异常策略／伪造诊断回归。原生颜色／位置／闪烁与物理机械臂仍未验收。
- `/tmp/mobileharness-bluetooth-status-check-delivery.log`：静态／格式／Python6通过，AppWorkflow126通过；UI99中1失败（cameraNativeMetalDrawStopAndLayerHandoff），Integration1004中10失败／17issues（publicationOverflow、atomicStableOffTarget、7项soundSource及mediaTransportExpiry），总11失败，退出1；不记为全量通过，未证明失败与本次无关。早期全量旧路径失败保留于check-final日志，不覆盖为通过。
- `/tmp/mobileharness-bluetooth-status-simulator.log`：CoreAIShared解析CoreAI失败，退出65，后续scheme未执行。`/tmp/mobileharness-bluetooth-status-device.log`：签名真机构建通过；最终25项应用资源、project/privacy/entitlements及diff检查通过。
- `/tmp/mobileharness-bluetooth-status-install.log`：设备连接不可用，CoreDevice4016，安装失败。当前真机尚未运行本版（包含此前首页模型准备改动）；需重连解锁后安装并验证。本轮未自动提交，工作仍在codex/storage-lifecycle-boundary，未修改main-sh，保留既有改动。

## 四基础根与完整异常保留（2026-10-19）

- 核对 StorageContainer（state/cache/database/files）、PlatformContainer（audio/vision/connectivity）、ModelContainer（language/speech/vision/artifacts）、UIContainer（八子能力）均由 App 的独立 ApplicationContainer 缓存并纳入生命周期；基础模块无相互项目依赖。
- 原生错误报告统一采用 component/operation/any Error；保留各 SDK 类型化 throw，不创建跨基础库错误依赖。根级记录增加原始 Error 与完整描述，Signal 保持有界摘要。取消／生命周期控制改为 suppressed 本地记录；蓝牙连接条件由 ApplicationControl 选择状态 Action，严重错误策略不变。
- 完整异常指当前有界记录保留原始对象和关联信息，非无限永久审计；128条以外明确淘汰计数。UI 过期提交仍是 Bool/拒绝计数协议，不伪造成执行故障。
- 模型根启动、前后台、停止及配置前置拒绝完整上报；装配停止不再吞掉非取消错误。恢复 Xcode Management 源码组并清理过时单例说明。
- 首次定向验证：`/tmp/mobileharness-foundation-errors-targeted.log`，12项通过；覆盖完整原生错误／长文本区分、四根注册与生命周期错误、回滚主错误及清理错误、正常取消留存但不广播、既有容器通道。源码边界检查、工程及隐私清单lint通过。
- 完整检查、最终定向回归与签名构建结果见本节后续记录。设备验证未执行；本轮按用户要求提交全部工作区修改，不包含模型权重、媒体或本地签名配置。

最终验证：

- `/tmp/mobileharness-foundation-errors-final-regression.log`：最终源码定向12项通过。
- `/tmp/mobileharness-foundation-errors-check.log`：完整脚本退出1；源码边界、Python6项、Swift格式检查通过，AppWorkflow126项通过；UI99项中1个测试失败（cameraNativeMetalDrawStopAndLayerHandoff）；Integration1006项中9个命名测试失败、19个issue：voiceReplyCancellationJoinsPlaybackBeforeRetiringSessionAudio（3参数用例），soundSource的StopCancelsAndJoinsAnInFlightPublisher、MonoIsUnavailableAndRejectedPublicationDoesNotStopRecognition、BroadcastCrossesGatewaysWithBoundIdentityAndCaptureDeadline、NonSpeechBroadcastDoesNotRequireSubscribersOrOpenASR、ReplyGateClearsDirectionAndResumeStartsANewWindow、OnlyDiagnosticCrossesGatewaysWithoutModelsOrPresentationGrants、SlowSubscriberDoesNotBlockFollowingDirections、ContextWriteFailureReportsWithoutStoppingOrSelfJoin。合计10个命名失败测试，不宣称与本轮无关或全量通过。
- `/tmp/mobileharness-foundation-errors-simulator.log`：build-ios脚本退出65，CoreAIShared的Simulator编译失败，其余scheme未执行。
- `/tmp/mobileharness-foundation-errors-device.log`：签名iOS真机构建成功；应用25项Skill资源与声明检查通过。未安装／未进行本轮物理验收。
- 提交是当前全部工作区的检查点，包含前序模型容器化、Gemma无system诊断版、音频启动隔离、首页准备和蓝牙状态改动；真实模型指令行为、首token时延、硬件及全量失败仍各自待验证，不因提交而关闭。

## 四基础模块异常结构统一（2026-10-19）

- 实施前工作区干净，基线为`61d1c72a`，没有重复创建空提交；仍在`codex/storage-lifecycle-boundary`，未改`main-sh`。本轮实现修改未自动提交。
- 四个独立SDK分别声明StorageFailure／PlatformFailure／ModelFailure／UIFailure，均为Error／Sendable／CustomStringConvertible；同形Code、component、operation、message、underlying、cleanupErrors、Source(fileID/function/line)。根生命周期使用类型化throws；容器原生报告出口交付同形封装。底层领域能力协议仍可抛原始错误，不能宣称全SDK每个throw都已替换。
- 保留原始NSError身份／userInfo及全部清理错误；重复同模块包装保留首次来源。Source是包装／报告位置，不是原始throw堆栈。无清理失败的取消通过明确标记抑制广播；单项或多项清理失败均不得被降为取消、生命周期拒绝或蓝牙连接状态。
- App仅投影技术code／取消标记并维持宿主取消语义；Gateway独占Signal编码及有界摘要。基础SDK不生成业务提示、重试或状态机策略。原有根／制品／数据库准备的五种专用复合清理错误已删除，其他领域原生错误保留。
- 结构漂移／独立依赖静态检查通过；新增同一测试协议校验四结构语义。最终定向`/tmp/mobileharness-error-schema-final-regression.log`：61项、5 suites全部通过，覆盖根生命周期／回滚／主与清理错误／取消／同根注册／蓝牙状态与UI根完整回归。较早定向47项通过后，增加单项清理不降级用例及完整UI根回归。
- `/tmp/mobileharness-error-schema-check.log`为首次全量运行，包含三处旧UI根错误类型断言失败；已按新的类型化根契约修正，后续定向已通过。最终全量结果记录在本节后续，不把定向结果替代完整检查。
- `/tmp/mobileharness-error-schema-simulator.log`：Simulator构建退出65，第三方CoreAIShared在arm64／x86_64编译失败；后续scheme未执行。
- `/tmp/mobileharness-error-schema-device.log`：签名iOS真机构建成功，最终应用25项Skill资源／函数声明检查通过；工程、隐私清单及entitlements lint通过。本轮未安装／未做硬件、原生UI或真实模型验收。

最终全量检查：`/tmp/mobileharness-error-schema-final-check.log`，退出1。源码依赖／结构漂移、Python6项、Swift格式检查通过；AppWorkflow126项通过。UI99项中1个命名测试失败（cameraNativeMetalDrawStopAndLayerHandoff）；Integration1012项中10个命名测试失败、20个issue：voiceReplyCancellationJoinsPlaybackBeforeRetiringSessionAudio（3参数用例）、atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、soundSource的BroadcastCrossesGatewaysWithBoundIdentityAndCaptureDeadline／StopCancelsAndJoinsAnInFlightPublisher／MonoIsUnavailableAndRejectedPublicationDoesNotStopRecognition／NonSpeechBroadcastDoesNotRequireSubscribersOrOpenASR／ReplyGateClearsDirectionAndResumeStartsANewWindow／OnlyDiagnosticCrossesGatewaysWithoutModelsOrPresentationGrants／SlowSubscriberDoesNotBlockFollowingDirections，以及visionResolvesOpaqueInputWithoutCopyingMediaIntoObservation（60秒超时）。合计11个命名失败测试；三处旧UI根断言已不再失败，定向61项通过，不宣称全量失败均与本轮无关。最终工程／隐私清单lint及diff格式通过；物理设备、模型与完整集成失败仍待单独验收。

设备重新连接后：`/tmp/mobileharness-error-schema-install.log`确认安装成功（databaseSequenceNumber 4196）；`/tmp/mobileharness-error-schema-launch.log`确认启动dev.mobileharness.app成功。安装的是包含首页模型准备与本轮异常结构统一的最新签名构建；用户功能验收结果尚待反馈，不将安装／启动成功视为硬件或模型验收通过。

## 独立加载表情Action与真机复测（2026-10-19）

- 根因：旧方案只改变VoicePhase.loading，但displayedExpression在未聆听时仍强制closed，原生表面也无独立加载循环。
- App拥有模型准备，只报告modelPreparation环境事实；Gateway→ApplicationControl→代码私有UI.Expression.setLoading（direct/returning状态Tool）→UI.home.expressions。传入enabled/revision，完成表示状态接纳，非模型完成／GPU回执。未增加模型Skill、线程、Canvas或逐帧Task。
- loading为独立眼睛形状，Core Animation 1.2秒双眼交替透明度／位移、相位差0.6秒。关闭聆听也能显示，减少动态效果静态呈现。终态／失活同步清理；旧revision和后台开启被拒。每个新事实版本均提交，处理快速前后台造成idle被事实合并的情况。有限表情被接管时取消真实等待者，加载期间不伪造其他表情完成；启动占位在Agent不可用时共用loading形状。
- `/tmp/mobileharness-loading-expression-receipts-tests.log`：最终定向12项通过（UI5、Gateway/Agent/Action端到端1、App准备生命周期6），包含前后台重新开启、根和版本拒绝、无聆听呈现、取消旧回执与busy拒绝。全量运行后追加的回执保护以此定向和最终签名构建验证，未因此宣称全量通过。
- `/tmp/mobileharness-loading-expression-check.log`：完整检查退出1；源码边界／结构检查、Python6项及Swift格式通过；UI102项、AppWorkflow126项通过。Integration1013项中14个命名测试失败、27个issue：nexArmIntermediateTimeoutAdvancesAndReportsMissingSegmentAfterEnding、nexArmPlaybackCongestionRejectsWithoutReplayingMotion、voiceReplyCancellationJoinsPlaybackBeforeRetiringSessionAudio（3参数）、atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、soundSource的MonoIsUnavailableAndRejectedPublicationDoesNotStopRecognition／BroadcastCrossesGatewaysWithBoundIdentityAndCaptureDeadline／StopCancelsAndJoinsAnInFlightPublisher／NonSpeechBroadcastDoesNotRequireSubscribersOrOpenASR／ReplyGateClearsDirectionAndResumeStartsANewWindow／OnlyDiagnosticCrossesGatewaysWithoutModelsOrPresentationGrants／SlowSubscriberDoesNotBlockFollowingDirections，及visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers／visionStatisticsMeasureCaptureToResultThroughPoseTool／visionRejectsMismatchedCaptureBeforeCallingModel。不声明均与本轮无关。
- `/tmp/mobileharness-loading-expression-simulator.log`：Simulator退出65，CoreAIShared arm64/x86_64编译失败，后续scheme未运行。
- `/tmp/mobileharness-loading-expression-final-device.log`：最终签名真机构建成功；最终应用25项Skill资源与声明检查、工程／隐私清单lint及diff检查通过。
- `/tmp/mobileharness-loading-expression-final-install.log`确认安装成功（databaseSequenceNumber 4212）；`/tmp/mobileharness-loading-expression-launch.log`确认启动dev.mobileharness.app成功。双眼实际观感、加载时长和硬件行为仍待用户反馈，安装不等于验收。保留之前异常结构统一工作区修改，本轮未提交。

用户真机反馈（2026-10-19，安装序号4212）：关闭聆听情况下触发模型准备，双眼加载动画及退出恢复均正常。该反馈确认本轮加载表情呈现与退出行为，不扩展为模型稳定性、全部硬件流程或全量测试通过；上述自动化失败和Simulator阻断仍保留。

## setLoading完成回执修复（2026-10-19）

- 用户确认动画及退出正常后报告setLoading/invalidCompletion。根因是state函数注册返回value("presented")；真实FunctionExecutor只允许state→completed，所以UI副作用已发生，随后完成校验才报错。此前只检查UI状态的端到端测试未发现失败回执，不能把之前的测试作为完成契约已验证的证据。
- ExpressionActions.setLoading改为Void，UIModule及集成fixture均使用handler注册自动生成completed；未放宽Gateway校验，也未改为finite掩盖契约错误。
- 新增loadingExpressionStateCompletionPassesRealExecutorAndReturningTool，从生产UIModule取得定义，经过真实ToolExecutor／FunctionExecutor，分别检查开启／关闭均isError=false、failureCode=nil、completion=.completed及value="completed"。
- `/tmp/mobileharness-loading-completion-final-tests.log`：4项定向通过（UI2、Integration2），包括真实完成回执、Gateway→Agent→Expression及加载与有限表情回执隔离。
- 完整检查、Simulator、最终签名及安装结果见本节后续；动画效果前轮真机反馈仍保留，本轮新增完成回执需要独立确认。

最终验证：`/tmp/mobileharness-loading-completion-check.log`完整检查退出1，源码边界／结构、Python6项、格式通过，UI103项及AppWorkflow126项通过；Integration1014项中13个命名测试失败／24个issue：voiceReplyCancellationJoinsPlaybackBeforeRetiringSessionAudio（3参数）、atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError、publicationOverflowDoesNotWaitForDiagnosticCallbacks，soundSource的MonoIsUnavailableAndRejectedPublicationDoesNotStopRecognition／StopCancelsAndJoinsAnInFlightPublisher／BroadcastCrossesGatewaysWithBoundIdentityAndCaptureDeadline／NonSpeechBroadcastDoesNotRequireSubscribersOrOpenASR／ReplyGateClearsDirectionAndResumeStartsANewWindow／OnlyDiagnosticCrossesGatewaysWithoutModelsOrPresentationGrants／SlowSubscriberDoesNotBlockFollowingDirections／ContextWriteFailureReportsWithoutStoppingOrSelfJoin，以及visionRejectsMismatchedCaptureBeforeCallingModel、mediaTransportSurvivesExpiryDuringDispatchAndDisplaysNextFrame。不声明全量通过或失败均无关。

`/tmp/mobileharness-loading-completion-simulator.log`退出65，CoreAIShared编译阻断，后续scheme未运行。`/tmp/mobileharness-loading-completion-device.log`签名构建成功，最终App资源25项检查通过。`/tmp/mobileharness-loading-completion-install.log`确认安装成功（序号4220）；启动结果见`/tmp/mobileharness-loading-completion-launch.log`，本轮回执修复真机验收待反馈。修改未提交。

启动失败补充：CoreDevice 10002／FBS Security preflight拒绝；随后`/tmp/mobileharness-loading-completion-lock.log`确认passcodeRequired=true，需用户解锁后再启动。不能将安装成功记为已启动或真机回执验收通过。

## 首页检查与加载表情分离

用户确认 setLoading / invalidCompletion Toast 已解决；返回首页暖模型检查仍短暂播放加载眼睛。本轮将 checking 与 preparing 分开，加载后复查回到 checking，启动占位保持闭眼。

- 定向自动化：13 项通过（UI 4、集成 2、App 生命周期 7）；覆盖 checking 拒绝迟到开启、加载后退出、真实加载 Action 完成及暖模型反复进入首页。证据 `/tmp/mobileharness-loading-separation-tests.log`。
- Simulator：退出 65，CoreAIShared 的 arm64／x86_64 编译失败，后续 scheme 未运行。证据 `/tmp/mobileharness-loading-separation-simulator.log`。
- 完整检查：退出 1；UI 103 项、AppWorkflow 127 项通过。集成 1014 项运行产生 20 个问题，涉及音频取消清理、运控截止及 SoundSource（包括 60 秒超时）；不记为全量通过。证据 `/tmp/mobileharness-loading-separation-check.log`。
- 签名真机构建成功，25 项 App 资源检查通过，已安装并启动连接的 iPhone。证据 `/tmp/mobileharness-loading-separation-device.log`、`/tmp/mobileharness-loading-separation-install.log`、`/tmp/mobileharness-loading-separation-launch.log`。
- 新行为真机验收待用户复测：暖模型返回首页不显示加载眼睛；切换到需要真实加载的模型后返回首页才显示，完成即退出。构建及自动化不代替真实模型验收。

## 蓝牙连接超时状态呈现

用户报告机械臂连接超时仍弹基础能力异常。原生快照上报 timeout(connecting)，connect 返回 NexArmError.timeout，后者缺少连接阶段分类。Gateway 已按 connect 操作补齐原始 timeout 分类，ApplicationControl 继续仅调用状态呈现 Action，保留完整原始错误。

- 定向蓝牙自动化 8 项通过，覆盖原始／封装连接超时、原错误保留、无 Toast、写入及响应超时边界和清理错误不可降级。证据 `/tmp/mobileharness-bluetooth-timeout-tests.log`。
- Simulator 构建退出 65：CoreAIShared 无法解析 CoreAI 模块依赖，后续 scheme 未运行。证据 `/tmp/mobileharness-bluetooth-timeout-simulator.log`。
- 完整检查退出 1：UI 103 项、AppWorkflow 127 项通过；集成 1015 项运行产生 21 个问题，涉及 Toast 到期时序、音频取消清理、运控截止、SoundSource 和视觉结果超时，不记为全量通过。证据 `/tmp/mobileharness-bluetooth-timeout-check.log`。
- 签名真机构建成功，25 项 App 资源检查通过。证据 `/tmp/mobileharness-bluetooth-timeout-device.log`。
- 已安装并启动连接的 iPhone；证据 `/tmp/mobileharness-bluetooth-timeout-install.log`、`/tmp/mobileharness-bluetooth-timeout-launch.log`。机械臂真实连接超时不弹 Toast、顶部状态正确及重新连接的硬件场景仍待用户验收；自动化不代替真实设备。

## setLoading 正常取代与拒绝分离

用户报告 setLoading stale。当前 Bool 把旧版本、准备完成后的迟到加载、后台接纳和真正非法提交一并变为 stale。已使用 UI 自有 applied／superseded／rejected 结果分类；被跳过的版本仍记录水位，禁止旧开启重放，同版本冲突仍拒绝。Action 将正常被取代视为状态投影完成，不冒充动画完成。

- 定向自动化 4 项通过（UI 2、集成 2），真实 ToolExecutor 表驱动覆盖正常开关、checking／ready 迟到、乱序、同版本重放、冲突、零版本及错误来源。证据 `/tmp/mobileharness-loading-stale-tests.log`。
- Simulator 构建退出 65：CoreAIShared 无法解析 CoreAI 模块，后续 scheme 未运行。证据 `/tmp/mobileharness-loading-stale-simulator.log`。
- 完整检查退出 1：UI 103 项、AppWorkflow 127 项通过；集成 1015 项产生 28 个问题，涉及运控拥塞／截止、Toast 到期、音频取消清理、SoundSource 与视觉时序／超时，不记为全量通过。新增会话接管回归也随完整 UI 套件通过。证据 `/tmp/mobileharness-loading-stale-check.log`。
- 签名真机构建成功，25 项 App 资源检查通过，证据 `/tmp/mobileharness-loading-stale-device.log`。已安装并启动连接的 iPhone，安装／启动证据 `/tmp/mobileharness-loading-stale-install.log`、`/tmp/mobileharness-loading-stale-launch.log`；切页返回、快速完成和前后台下无新增 setLoading stale 的真实模型场景待用户验收。

## 首页加载提示真实边界

用户报告仍有瞬时 setLoading。检查文字层仍由 blocksNewActions 控制，且 registered 的无资源后端构造会被 prepare 入口误报为加载。已将加载报告移至 ModelResource actor 内真实无缓存加载分支；缓存命中和 unmanaged 不发加载。App 不再在 prepare 入口投影 preparing，UI 以独立 showsStatus 控制文字／按钮；不使用人为延时隐藏真实加载。

- 定向 15 项通过：UI 4、ModelKitRuntime 1、集成 2、AppWorkflow 8。覆盖真实加载／失败成对回调、暖模型及 unmanaged 无回调、对象装配不显示、代际围栏及 Action 完成。证据 `/tmp/mobileharness-real-loading-final-tests.log`。
- ModelKit 语音 warmup 与 load／status 一致使用当前选中的后端。
- 完整检查、签名构建、提示音原生隔离与真机结果另行记录。

## 按住唤醒整屏短暂停顿采样

用户明确为整个界面短暂无响应后恢复，并在 45 秒采样中复现。`/tmp/mobileharness-wake-system-20261019.trace` 的 potential-hangs 记录主线程约 739.98 ms、1114.42 ms 两次停顿。Time Profiler 只在停顿结束附近采到少量运行栈，不能将整段阻塞时长都归因同一函数；UUID 匹配的应用二进制符号解析确认其中栈落在 NativeCuePlayback.swift:81 的 prepareToPlay／play，另有 UI 更新及麦克风采样转换。待将提示音启动迁至私有音频 actor；尚不宣称所有卡顿根因已经排除。单进程 attach 两次未找到目标，改用设备全进程采样成功。

### 本轮最终构建与检查

- 签名真机构建成功，25 项打包资源检查通过，安装及启动成功：`/tmp/mobileharness-real-loading-device.log`、`/tmp/mobileharness-real-loading-install.log`、`/tmp/mobileharness-real-loading-launch.log`。原生提示音图的 iOS 代码由该构建验证，不以 macOS 测试冒充原生音频验收。
- 最新源码的 Simulator 脚本退出 65，CoreAIShared 无法解析 CoreAI 模块（arm64／x86_64），后续 scheme 未运行：`/tmp/mobileharness-real-loading-final-simulator.log`。
- 完整检查退出 1：UI 103 项有 1 项相机到期时序失败，AppWorkflow 128 项通过；集成多项失败／超时，超时报告后仍挂住超过三分钟，终止本次测试子进程让后续目标继续，集成套件未完整完成，不记为通过：`/tmp/mobileharness-real-loading-final-check.log`。
- 第二次 45 秒设备采样 `/tmp/mobileharness-wake-fixed-20261019.trace` 的 potential-hangs 表为空，未发现阈值 250 ms 以上的停顿。尚待用户确认该窗口确实完成唤醒动作及提示音正常，不据此宣称硬件体验已验收。

- 构建结束后单独复核 16 项均通过（UI 5，含相机到期；ModelKitRuntime 1；集成 2；AppWorkflow 8）：`/tmp/mobileharness-real-loading-final-regression.log`。该结果不覆盖或抹去完整套件的失败／中断。源码边界及 diff 格式检查通过。

## 唤醒卡顿持续复现

用户确认提示音迁移后整屏短暂无响应仍存在，前次 potential-hangs 为空不能视为验收。重新启用 Time Profiler 的 recordWaitingThreads／contextSwitchSampling，90 秒设备全进程采集，用户确认重复唤醒已复现。待分析等待栈，再确定修改范围。

90 秒等待采样已确认两次主线程停顿（790.13 ms、1070.73 ms）；采样栈明确包含 `AppleAudioIO.performStop → AVAudioSession privateSetActive → NSXPCConnection synchronous reply → mach_msg`。提示音隔离未覆盖共享会话停用，是本轮实际修复点。记录保存时出现系统动态库地址重叠符号警告，导出成功，应用及系统等待栈均可解析。待修复会话释放边界。

### 会话停用隔离实现及验证

- `NativePlaybackGraph.deactivateSession` 在既有音频 actor 执行停用；AppleAudioIO 的短音频释放和全量 stop 共用一个 MainActor 拥有的释放任务并等待真实返回。任务结束前拒绝新 claim，任务内统一释放所有权并清除接纳围栏；错误完整保留，不新增专用线程或操作队列。
- 源码归属守卫和 diff 格式通过，禁止 AppleAudioIO owner 直接调用任何 setActive。
- 完整检查退出 1：UI 103 项、AppWorkflow 128 项通过，集成 1015 项完成并有 18 个问题（音频取消清理、运控截止、SoundSource），不记全量通过：`/tmp/mobileharness-session-release-check.log`。
- 签名真机构建成功，25 项 App 资源校验通过：`/tmp/mobileharness-session-release-device.log`。已安装并启动真机：`/tmp/mobileharness-session-release-install.log`、`/tmp/mobileharness-session-release-launch.log`。Simulator 脚本退出 65，CoreAIShared 无法解析 CoreAI 模块（arm64／x86_64），后续 scheme 未运行，证据 `/tmp/mobileharness-session-release-simulator.log`；硬件复测尚未验收，不能把源码隔离或编译结果等同体验修好。

## 用户澄清：长按开启聆听延迟

用户进一步明确：始终不是整屏冻结，实际问题是长按后开启录音和动画等待过久。此前对用户体验的“整屏冻结”描述应视为误解；系统 potential-hangs 和同步等待栈仅作为技术证据，不能等同用户症状。验收改为长按接纳到真实首 PCM／动画的延迟、提示音及正常收音。

代码确认 stopCapture 只结束采集，保留同一输入作用域拥有的共享会话；下次 startCapture 却无条件 full stop，产生已采到的停用 XPC 等待，再重新激活。已在同作用域空闲重启分支跳过多余 full stop，加入采集／播放清理并检查新占用；有活动／正在停止或释放时仍走完整停止。真实首 PCM 才接纳录音和聆听动画，不提前伪造就绪。

签名真机构建成功，25 项 App 资源检查通过：`/tmp/mobileharness-wake-latency-device.log`。完整检查退出 1：UI 103 项、AppWorkflow 128 项通过，集成 1015 项有 19 个问题，不记全量通过，证据 `/tmp/mobileharness-wake-latency-check.log`。Simulator 退出 65，CoreAIShared 无法解析 CoreAI，后续 scheme 未运行，证据 `/tmp/mobileharness-wake-latency-simulator.log`。安装并启动成功：`/tmp/mobileharness-wake-latency-install.log`、`/tmp/mobileharness-wake-latency-launch.log`。用户补充每次开启约 2～3 秒，本轮同作用域重启的实际耗时改善待真机复测；不以无系统 hang 代替录音开启延迟验收。

## 音频实验回归撤回

用户提供新证据：Listening 动作约 10.64 秒后 Action execution timed out；随后同一作用域出现 audio.spatial.start 与 callback 的 invalidFormat。具体卡住阶段尚未确认，不能仅凭截图归因提示音、捕获或声道。先撤回本轮三个原生文件的实验修改（NativeCuePlayback、AppleAudioIO、PCMClipEncoding），恢复本轮改动前已使用的播放器与完整启停路径；保留其余工作区修改及完整错误上报，不增加超时、不隐藏错误。录音开启2～3秒延迟仍开放；待重新验证真实启动、收音、提示音与反复开关后，再做单一有证据的优化。

恢复版三个原生文件已与 HEAD 对应文件逐字一致，撤回实现的源码形状守卫已删除，未触及工作区其他功能改动。UI 103 项通过；签名真机构建成功、25 项打包资源校验通过，证据 `/tmp/mobileharness-audio-restore-check.log`、`/tmp/mobileharness-audio-restore-device.log`。完整检查退出 1：AppWorkflow 128 项通过；集成 1015 项产生 38 个问题，未通过，不将回归撤回等同全量通过。恢复版安装成功，自动启动因手机锁屏被系统拒绝，证据 `/tmp/mobileharness-audio-restore-install.log`、`/tmp/mobileharness-audio-restore-launch.log`。Simulator 退出 65：CoreAIShared 无法解析 CoreAI 模块（arm64／x86_64），后续 scheme 未运行，证据 `/tmp/mobileharness-audio-restore-simulator.log`。真实收音复测仍待结果，不能宣称新增错误已被设备验收解决。

## 恢复版仍有正在唤醒后延迟

用户明确延迟位于显示“正在唤醒”之后，约 2～3 秒。改为在恢复后的原音频链路增加阶段区间，采样原生停止、配置、启动、首帧及反馈完成，不改变行为；先获得分段耗时再选优化点。正常收音是否完全恢复仍不能从这条延迟反馈自动推断。

## 模型准备新增环境事实的逆序回归

用户截图显示 applicationControl input rejected: outOfOrder。Gateway 单向广播不保证并发到达顺序，而接收方原先将旧环境快照作为故障；新增 modelPreparation loading/idle 事实使该路径更易触发。待将环境快照改为按类别版本归约，保留来源与内容校验、同版本冲突拒绝。唤醒延迟仍独立开放，不以消除该错误代表录音启动性能已解决。

环境快照归约已实现。针对性 3 项通过，覆盖逆序／重复不重复发出 loading 呈现、同版本冲突／非法值／错误会话拒绝、类别版本独立，以及既有 Gateway→Agent→Expression Action 回归：`/tmp/mobileharness-environment-revision-tests.log`。前次耗时采样完整检查发生集成超时后挂起，终止测试子进程以继续其余目标；该次 UI 与集成失败，不记全量通过，证据 `/tmp/mobileharness-wake-timing-check.log`。新增音频／唤醒区间只用于分段测量，当前尚无带这些区间的真机采样，不宣称延迟已修复。

本次签名构建及 25 项 App 资源校验通过；安装、启动成功：`/tmp/mobileharness-environment-revision-device.log`、`/tmp/mobileharness-environment-revision-install.log`、`/tmp/mobileharness-environment-revision-launch.log`。完整检查退出 1：UI 103 项、AppWorkflow 128 项通过，集成 1016 项完成但有 42 个问题（包括声源、运控、相机时序），不记全量通过：`/tmp/mobileharness-environment-revision-check.log`。Simulator 构建退出 65：CoreAIShared 无法解析 CoreAI 模块，后续 scheme 未运行：`/tmp/mobileharness-environment-revision-simulator.log`。分段采样已保存 `/tmp/mobileharness-wake-stages-20261019.trace`，复现确认及区间分析仍待完成。

用户确认仍可复现等待。首次 55 秒采样未读到新增阶段标记，不能据此推算分段耗时，也不能确认复现动作落在记录窗口内。扩大下一次采样到 90 秒并显式加入 os_signpost 与等待线程记录；不再修改音频行为。

### 唤醒分段采样结果（用户确认复现）

90 秒记录 `/tmp/mobileharness-wake-stages-full-20261019.trace` 显式加入 os_signpost 并记录等待线程；保存及导出过程有系统 dylib overlap 警告，但导出成功。原始区间 `/tmp/mobileharness-wake-stages-full-signposts.xml`，相同时间和 ID 的重复事件去重后，得到四次原生启动：

| 区间 | 实测耗时 |
| --- | --- |
| ASR 可用性 | 2.37～4.16 ms（完整三次） |
| TTS 可用性 | 53.81～80.06 ms（完整三次） |
| VAD 可用性 | 22.70～23.08 ms（完整三次） |
| 权限／感知接纳 | 各低于 0.1 ms |
| Capture.Reset | 847.42～1021.80 ms |
| Capture.SessionConfiguration | 33.05～38.79 ms |
| Spatial.StartRunning | 75.17～78.70 ms |
| Spatial.FirstPCM | 2188.70～2196.35 ms |
| Wake.NativeCapture | 3156.94～3328.37 ms |
| Wake.NativeCue | 1222.10～1287.81 ms |
| Wake.Activation | 4667.70～4688.23 ms（完整三次） |

首次部分区间开始早于采样可用事件，不能把缺失起点计为零。主要等待在完整音频重置和 FOA 首帧，能力检查约 0.1 秒；没有证据将几秒延迟归因于本次可用性检查或模型加载。区间证明延迟仍存在，尚未修复，不代表系统 FOA 首帧耗时不可优化。没有关闭空间能力、提前伪造录音就绪或延长超时。普通聆听是否允许只用单声道会改变声源定位能力，已向用户确认该业务要求；未擅自改变。

## 继续追溯此前已验收基线

用户指出此前四声道没有延迟，拒绝以降级单声道代替回归定位。git diff 6431d36f..61d1c72a 确认模型容器化提交同时迁移了音频会话配置执行位置／准备 Task，以及空间捕获 session 的构造和释放时机。当前恢复到 HEAD 仍包含这两处变化，不能视为回到此前已验收基线。待只恢复这两处调用顺序作对照，保留当前错误上报、token、首帧校验及阶段计时；不改变四声道能力。

对照实现已构建、安装并启动，25 项资源验证通过：`/tmp/mobileharness-capture-baseline-device.log`、`/tmp/mobileharness-capture-baseline-install.log`、`/tmp/mobileharness-capture-baseline-launch.log`。完整检查退出 1：UI 103 项、AppWorkflow 128 项通过，集成 1016 项有 21 个问题，不记全量通过：`/tmp/mobileharness-capture-baseline-check.log`。本次对照不是全仓回滚：仅恢复会话配置与空间 session 构造顺序，保留 token 取消隔离、错误链路和分段计时。用户未授权降级，继续保留四声道；已启动 90 秒对照采样，延迟改善尚待确认。

对照版 Simulator 脚本仍退出 65，CoreAIShared 无法解析 CoreAI，后续 scheme 未运行：`/tmp/mobileharness-capture-baseline-simulator.log`。本次未提交任何修改。

用户回复对照版“已复现”。对照 trace 已保存 `/tmp/mobileharness-wake-baseline-20261019.trace`，但导出 `/tmp/mobileharness-wake-baseline-signposts.xml` 未包含任何 Wake／Spatial／Capture 区间；不能确认复现动作落在采样窗口内，不能从此记录得出性能前后差值。用户反馈仍作为延迟未解决的证据；未宣称两处恢复已修好。已撤销“普通聆听改用单声道”的方向假设，保持声源定位能力。尚待隔离首页模型预准备的间接影响；该功能当前仍保留，未继续叠加未验证音频改动。

## 当前工作区全部暂存并安装供复测

按用户要求，当前 89 个文件全部暂存（含新增文件），未提交；没有为此新增功能修改。签名构建成功，25 项 App 资源检查通过，安装并启动成功：`/tmp/mobileharness-staged-device.log`、`/tmp/mobileharness-staged-install.log`、`/tmp/mobileharness-staged-launch.log`。沿用上一轮完整检查失败记录，不将本次签名构建视为全量测试通过。

只读核对蓝牙与唤醒连接：CBCentralManager 回调使用 main queue；connect 通过 continuation 等待原生完成，12 秒超时使用 Task.sleep，不是同步睡眠。VoiceRuntimeDependencies 不注入蓝牙，beforeVoiceStart 只加入音频检测停止，prepareVoice／admitVoice 不等待机械臂连接；已启动的 AgentInteractionRuntime.start 直接返回。未发现唤醒串行等待 BLE connect 的路径；共享主线程回调的间接竞争未通过这次代码阅读排除，仍以用户复测及必要的同条件对照为准。

## 忽略机械臂后仍延迟：提交基线对照

用户确认忽略机械臂蓝牙后仍有唤醒等待。计划用最后提交 61d1c72a（已有模型容器化、尚未加入首页自动模型准备）构建一个粗粒度基线对照。当前全部修改先保留为 Git 暂存树，临时恢复工作区为该提交供构建，构建结束无论成功失败都恢复暂存树对应源码。只在真机安装基线，不丢弃或提交当前修改，不新增诊断功能开关，不以此对照宣称已锁定单一文件根因。该版尚无后加的首页模型预加载；原生首帧和模型使用时的实际验证仍由该提交原实现负责。

基线签名构建成功，25 项资源校验通过；安装、启动成功：`/tmp/mobileharness-committed-baseline-device.log`、`/tmp/mobileharness-committed-baseline-install.log`、`/tmp/mobileharness-committed-baseline-launch.log`。构建期间工作区与 61d1c72a 一致，暂存树 5708862771765cc2c6127f668bbe0d7c487933bb 保留全部修改；构建后从该树完整恢复，工作区与暂存区无差异。真机当前运行的是提交基线，并非恢复后的源码；未把基线构建标为当前修改已修复。本次仅做提交基线编译／安装，没有重新执行完整测试和 Simulator 构建；当前修改的前次失败记录保持。已请求用户区分首次与重复开启聆听的延迟，硬件结论待复测。

## 更正：61d1c72a 不是无首页预加载基线

用户在对照版仍看到 loading 闪现。重新直接读取提交源码，确认 61d1c72a 的 ServiceFactories 已有 ForegroundPreparation 和 warmup；此前“该提交没有首页自动模型准备”的结论错误，相关记录只能作为当时误判的历史，不能用于性能归因。用户要求保存全部当前修改并回到前一个提交；将使用 git stash（含新增文件）完整保存，保留原分支提交，再 detached 切到 6431d36f 进行干净构建和安装。该提交早于模型容器化及首页准备。当前全部修改不会自动恢复或提交；后续恢复需使用对应 stash，并保留暂存状态。

## 旧基线重启后仍有唤醒等待：展示阶段边界

用户确认 6431d36f 重启 iPhone 后，显示“正在唤醒”约 2～3 秒才进入聆听。保持原 stash 76137e968f194f0d5e86208b22265ce18a182ae3 不动，从此基线创建修复分支。只读核对发现 startMicrophone 接纳首 PCM 后提交 isVoiceActive 和 listeningAnimationID，却未结束 loading 展示；startVoice 直到捕获及 cue/haptic 整体完成才结束该阶段。此前采样提示音区间约 1.22～1.29 秒，该展示等待不能用于解释首帧之前的约 2.19 秒。待将展示阶段切换移动到真实收音就绪边界，保持反馈动作完整等待及失败语义；不缩短超时、关闭空间能力或伪造录音成功。ConversationView 的“正在加载模型”是辅助功能标签，非页面下方可见文字，需同步纠正。

本次仅修改业务呈现时机及辅助功能标签，原生格式／启停／就绪与反馈完成契约保持。签名构建及 25 项 App 资源校验通过，安装、启动成功，手机独立查询确认 bundleVersion=643137：`/tmp/mobileharness-listening-state-device.log`、`/tmp/mobileharness-listening-state-install.log`、`/tmp/mobileharness-listening-state-launch.log`、`/tmp/mobileharness-listening-state-installed.json`。原 stash 保留。已请求用户复测唤醒展示、提示音与收音；未将构建等同启动延迟已修复。

用户反馈 643137 未缩短等待，展示时机补丁不构成性能修复。完整检查退出 1：UI 96 项、AppWorkflow 120 项通过；集成 1000 项有 29 个问题，不记全量通过，日志 `/tmp/mobileharness-listening-state-check.log`。Simulator 退出 65：CoreAIShared 无法解析 CoreAI，后续 scheme 未运行，日志 `/tmp/mobileharness-listening-state-simulator.log`。将本轮四处业务／UI 源码与 README 恢复到 6431d36f，保留本验证记录；撤出的补丁保存在 `/tmp/mobileharness-listening-display-only.patch`，不混入后续修复。原 89 文件 stash 仍保留。手机仍为已安装 643137，未再安装其他版本。

### 10 月 18 日唤醒历史逐项对比（只读）

对比 2494f4ea（10:19）、b846d323（17:04）、9426eb47（17:35）、39a48417（19:03）、6431d36f（19:18）。五个提交的 AppleSpeechRecognition.swift SHA256 均为 ee1182e74e73bb5c3cdd96cb4f7975a6a63e04594129faff80acc6680752a4b3；prepareVoice 均依次检查 recognition/synthesis/voiceActivity availability，再请求音频权限，没有调用识别 warmup。结构化证据 `/tmp/mobileharness-wake-yesterday-comparison.json`。

- 8305a380（10 月 16 日 01:05）的真实时序变化：删除 prepareRecognition 及其 warmup 调用、删除按压时 audio.prepareClip 原生预备调用；activation 阶段原为 prepare／cue／haptic 并行，随后 120 ms tail 再 capture，改为 preparation → capture → feedback。isVoiceActive／listeningAnimationID 从代际创建立即设置改为首 PCM 接纳后设置。昨天所有对照提交已含该变化；它解释反馈为何晚于录音启动，不证明录音物理首帧因此变慢。
- b846d323（10 月 18 日 17:04）将输出 AVAudioEngine 迁往 NativePlaybackGraph actor，加入 playbackCleanup／stopOperation 取消清理加入；首帧、四声道及录音配置策略没有因 UI 协议化改变。
- 39a48417（10 月 18 日 19:03）将回复取消从并行改为 cancelReply → waitForPlaybackStop → cache cleanup。startVoice 在显示“正在唤醒”之前已经加入这些任务；不能直接将显示之后的 2～3 秒归因于这处变更。
- 实际线程边界：AppleAudioIO 的 setCategory/setActive 及完整 stop 中 setActive(false) 仍在 MainActor 同步执行；此前停用区间测得 0.85～1.02 秒，有系统同步等待栈。SpatialAudioCapture.startRunning 在捕获 actor 执行，约 75～79 ms；readiness.wait 约 2.19 秒是挂起等待首个有效 PCM，不等于主线程同步阻塞。
- AppleSpeechRecognition.warmup 只 acquire/release Locale 资源（语言支持和安装资产），不是 SpeechAnalyzer.prepareToAnalyze；后者只在实际 transcribe 的 AnalyzerWorker.start 执行。SpeechRecognitionTurn 只在收到有效音频事件时 open/transcribe，所以不能凭“正在唤醒”文字推断正在等待 Apple ASR 分析器。

没有从这些对比得到“唯一根因已验证”的结论，不再要求重启或连续安装无明确假设的版本。

## 用户指定体验 8305a380

按用户明确指定，计划保存当前排查记录后 detached 检出 8305a380，执行签名干净构建并安装真机。此提交本身已经包含 preparation → capture → feedback 的时序变更；不自动改为其父提交。原 89 文件 stash 76137e968f194f0d5e86208b22265ce18a182ae3 保留，原分支不移动。通过独立构建号 8305380 核对构建产物和手机安装版本；此次只做历史版本体验，不新增功能代码。

## 恢复最新工作区继续排查

用户反馈 8305a380 仍慢，要求结束历史版本切换并恢复最新代码。已切回 codex/storage-lifecycle-boundary（HEAD 61d1c72a），以 --index 应用 stash 76137e968f194f0d5e86208b22265ce18a182ae3，核对恢复的工作区和暂存树与保存快照一致；恢复原 89 文件修改及暂存状态。后续只读审计记录从 stash 987a4cc813e887c2a346258ad6f90fd6b4b0f512 追加恢复；无效的 643137 展示补丁未带回。两份 stash 均保留，未新增提交。本次只做源码与记录恢复，未重新构建或安装；手机仍为之前安装的 8305a380（构建 8305380）。

## 最新工作区重新安装真机

按用户要求，基于已恢复的 codex/storage-lifecycle-boundary（HEAD 61d1c72a 加原 89 文件修改）执行签名干净构建，独立构建号 10192001。构建成功，25 项 App 资源校验通过；安装与启动成功，手机端独立查询 bundleVersion=10192001。日志：`/tmp/mobileharness-restored-latest-device.log`、`/tmp/mobileharness-restored-latest-install.log`、`/tmp/mobileharness-restored-latest-launch.log`、`/tmp/mobileharness-restored-latest-installed.json`。本次仅重新部署，没有新增功能修复、提交或更改原暂存状态；未重跑完整检查与 Simulator，既有失败记录保留。聆听延迟仍待后续定位，安装成功不代表性能问题已修复。

## 首页返回转场空白

用户截图显示设置页交互返回时，下方首页区域为空白，直到页面退出才显示。当前 PersistentHomeNavigation 将首页常驻在 NavigationStack 外，导航根只有 Color.clear，未显式声明导航容器透明；iOS 路径驱动的整体 opacity 也参与显示。待通过公开 containerBackground(.clear, for: .navigation) 清除根与目的页面的导航容器背景，目的页面使用自己的不透明背景，移除 iOS 导航层整体 opacity。保留首页身份、聆听与呈现状态、相机导航准入及辅助功能／命中隔离；不修改录音或模型流程。检查、构建与原生手势验收分别记录。

上述导航背景调整已实现，仅修改 PersistentHomeNavigation 的 UI 呈现。公开 API 说明：https://developer.apple.com/documentation/swiftui/containerbackgroundplacement/navigation 。`./scripts/check.sh` 退出 1：UI 103 项（含常驻首页多层导航原生挂载回归）、AppWorkflow 128 项通过，集成 1016 项有 34 个问题，不能记全量通过；日志 `/tmp/mobileharness-home-return-check.log`。既有挂载测试不验证 iOS 返回中间帧的可见像素，本轮不将它当作交互返回验收。`./scripts/build-ios.sh` 退出 65，CoreAIShared 无法解析 Simulator 的 CoreAI，后续 scheme 未执行：`/tmp/mobileharness-home-return-simulator.log`。

签名真机构建、25 项资源校验、安装及启动成功；手机独立查询确认构建号 10192002：`/tmp/mobileharness-home-return-device.log`、`/tmp/mobileharness-home-return-install.log`、`/tmp/mobileharness-home-return-launch.log`、`/tmp/mobileharness-home-return-installed.json`。原生验收待用户检查设置页返回手势拉至中间、取消返回、完成返回及深层返回时首页持续显示、聆听保持、相机离开暂停／返回恢复。无新增提交，原暂存修改保持。

用户确认构建 10192002 的返回手势问题“可以了”，作为本次返回场景的真机反馈；不扩大为全场景验收。

## 一轮结束恢复聆听时清理用户字幕

用户反馈只清除了 assistant 回复，已定稿用户字幕仍留在顶部。已核对 VoiceSessionCoordinator 在恢复收音确认后调用 homeEffects.replyDidFinish；现有 UI 实现只清理回复。待在同一业务完成边界清除已定稿用户文本及标记，保留未定稿新输入和既有回复淡出／替换／停止围栏，不在页面根据 voicePhase 推测轮次完成。

已在 HomeEffectsWorkflow 实现清理：有效前台聆听会话收到完成通知后，同步清除已定稿用户字幕；无回复文本也执行，未定稿新输入保留。新增两项测试（其中一项含有／无回复文本两个参数用例），定向回归通过：`/tmp/mobileharness-caption-restoration-tests.log`。完整检查退出 1：UI 103 项、AppWorkflow 130 项通过；集成 1016 项有 23 个问题，不记全量通过：`/tmp/mobileharness-caption-restoration-check.log`。Simulator 退出 65，CoreAIShared 无法解析 CoreAI，后续 scheme 未执行：`/tmp/mobileharness-caption-restoration-simulator.log`。签名真机构建和 25 项资源检查通过：`/tmp/mobileharness-caption-restoration-device.log`。真实回复结束／聆听恢复的字幕效果仍待真机验收，本轮未提交。

真机安装与启动成功，独立查询确认 bundleVersion=10192003：`/tmp/mobileharness-caption-restoration-install.log`、`/tmp/mobileharness-caption-restoration-launch.log`、`/tmp/mobileharness-caption-restoration-installed.json`。原暂存状态保持，原工作区修改保留。

## 四基础模块容器入口与异常定义归根

按用户要求统一文件布局：ModelContainer.swift、ModelFailure.swift、StorageFailure.swift 移至各自模块根；PlatformKit 现有根布局保留，并将 PlatformError 声明归入 PlatformFailure.swift。UI 已满足布局。保持编译目标、公开类型、运行时和 Signal 转换边界；更新 SwiftPM 源码清单、Xcode 导航、边界检查及当前 README，历史测量输入路径保持原始证据。验证待执行，不新增目录／目标／依赖，不自动提交或改变既有暂存。

布局调整已完成。三个移动文件 SHA256 与移动前一致，记录 `/tmp/mobileharness-foundation-layout-move-hashes.json`；PlatformError 仅移动声明位置，公开类型／case 保持。边界检查通过，包括四模块 Container／Failure 必须在物理根、文件唯一编译归属、错误结构一致及模型 Core 独立类型检查：`/tmp/mobileharness-foundation-layout-boundaries.log`。Xcode project plist 及 diff 格式检查通过；原暂存 89 文件未修改。

完整 `./scripts/check.sh` 退出 1：UI 103 项有 1 个问题（cameraNativeMetalDrawStopAndLayerHandoff 超时），集成 1016 项有 21 个问题，AppWorkflow 130 项通过：`/tmp/mobileharness-foundation-layout-check.log`。定向复跑的四模块异常结构 6 项通过，但原生 Metal 用例仍失败：`/tmp/mobileharness-foundation-layout-focused.log`；不记全量通过，也不将原生失败归因于目录移动或宣布其已解决。

`./scripts/build-ios.sh` 退出 65，CoreAIShared 无法解析 Simulator 的 CoreAI，后续 scheme 未执行：`/tmp/mobileharness-foundation-layout-simulator.log`。签名真机构建与 25 项资源校验通过：`/tmp/mobileharness-foundation-layout-device.log`。此次未安装或做硬件验收，手机仍为此前字幕修复构建 10192003；未自动提交。

## 首页加载仅大小眼、失败重试与异常 Toast

用户要求删除加载文字／取消按钮，加载不提供手动取消，只以左右大小交替的双眼表达等待；失败提供重试及业务异常 Toast。待移除手动取消端口／用户状态、简化首页恢复提示，保留实际加载事实 → ApplicationControl → Expression Action，修改 Core Animation 缩放并清理退出状态。ModelKit 已上报的加载失败沿现有 Gateway 异常链路；仅补齐宿主验证未就绪的原始错误上报，避免重复 Toast。生命周期失活／配置替换／根停止仍取消并加入，不承诺原生加载可即时中断。验证待执行，本轮不提交。

已完成：加载／检查无状态文字和按钮，failed 才有重试按钮；手动 cancel 端口／接线／cancelled 用户状态已移除。加载眼睛使用两个独立父图层的 Core Animation 缩放，1.2 秒内左右在 1.12／0.68 之间交换，移除原明暗／上下浮动；减少动态效果时静态大小眼，退出／失活恢复缩放。模型错误沿原通道，新增 ForegroundPreparation.ValidationError.notReady 的 onValidationFailure 报告，经同根 Gateway → ApplicationControl → 呈现函数显示 Toast，UI／App 不直接决定 Toast。

定向测试退出 0：UI 5 项（含表情几何参数用例）、集成 2 项、AppWorkflow 8 项通过；包含实际准备验证错误经过真实 Gateway／ApplicationControl 成为 Toast，原错误对象仍保留：`/tmp/mobileharness-loading-eyes-focused.log`。完整 `./scripts/check.sh` 退出 1：UI 103 项有 1 个原生 Metal 问题，集成 1017 项有 26 个问题，AppWorkflow 130 项通过：`/tmp/mobileharness-loading-eyes-check.log`。不记全量通过。

`./scripts/build-ios.sh` 退出 65，CoreAIShared 无法解析 Simulator 的 CoreAI，后续 scheme 未执行：`/tmp/mobileharness-loading-eyes-simulator.log`。签名真机构建、25 项资源校验、安装及启动通过；手机查询确认构建号 10192005：`/tmp/mobileharness-loading-eyes-device.log`、`/tmp/mobileharness-loading-eyes-install.log`、`/tmp/mobileharness-loading-eyes-launch.log`、`/tmp/mobileharness-loading-eyes-installed.json`。实际大小眼观感、真实模型失败／重试和前后台验收待用户确认；未提交，原 89 文件暂存保持。


## 2026-10-19 大模型请求等待眼睛

实现：Assistant 前台回复 Worker 在实际 chat 调用前经 Gateway 提交内部 UI.Expression.setReplyWaiting，按请求 ID 结束覆盖。首个非空文本、原生工具输出、无输出完成、流失败及建流失败均收尾；取消不向已关闭 round 注册新 Action，通过现有回复占用清空／根生命周期清理。复用原生大小眼，不修改音频、相机或预热，不增加线程。模型准备 checking／ready 与请求等待独立；有限表情有真实回执，不被等待装饰报 busy。

- 专项最终运行 `/tmp/mobileharness-reply-waiting-focused-final.log`：UI 5 项、集成 6 项（请求结束测试含 text／native／finish／failure／openFailure／cancel 六种参数）、AppWorkflow 1 项通过；包括单次流式回复只发一对等待标记、身份围栏、生命周期、模型准备独立及有限表情回执。使用注入模型，不代表真实模型表现。
- 首轮 `./scripts/check.sh` 未通过：UI 106 项有 3 个问题，集成 1019 项有 57 个问题。暴露旧机械臂 UI fixture 未提供新增内部函数、授权数量断言及测试把回复占用事实的 finished 误当请求终态；已修复相关测试宿主／关联校验，最终专项及后续全量对应测试通过。原始日志 `/tmp/mobileharness-reply-waiting-check.log` 保留失败证据。
- 最终 `./scripts/check.sh` 退出 1：源码边界、6 项 Python 检查及格式检查通过；UI 106 项仍有 1 个 Metal draw/stop/handoff 问题，集成 1019 项仍有 22 个问题（含环境逆序断言、播放清理、声源／视觉超时等），AppWorkflow 131 项通过。新增等待、配置目录与真实装配覆盖测试通过；全量失败不记为通过。日志 `/tmp/mobileharness-reply-waiting-check-final.log`。
- `./scripts/build-ios.sh` 退出 65：MobileHarnessSimulator 在 CoreAIShared 无法解析 CoreAI；后续三个 scheme 未执行。日志 `/tmp/mobileharness-reply-waiting-simulator.log`。
- 签名真机构建成功，最终应用 25 项 Agent/Skill 资源校验通过；构建日志 `/tmp/mobileharness-reply-waiting-device.log`。
- 已安装 iPhone 17 Pro，并通过设备应用清单独立核实 bundleVersion **10192006**（`/tmp/mobileharness-reply-waiting-installed.json`）。自动启动当时被系统 Locked 拒绝。随后用户解锁测试并反馈“有，正常”，确认大模型等待首个输出时出现大小眼动画，开始输出后正常恢复。该实机确认不扩展为失败／取消、全部模型或性能验收。
- 本轮未提交，原 89 个已暂存文件保持原索引，所有本轮变更留在工作区。


## 2026-10-19 聆听路径冗余清理

实现：按压预备仅准备触觉和提示音，不调用诊断停机或加入设备清理；真实 startVoice 保留一次互斥准备，移除同一区间重复等待。VoiceNativeEffects 以 prepareCue 唯一生成并持有一份私有 PCM 缓存，播放复用该入口，取消前后校验保留。AppleAudioIO 共用同步会话配置，各调用者仍按原隔离执行。计时只保留 Wake.Activation／Spatial.Start 总区间；撤下细分 wrapper，不引入新任务、线程、延时或预热。

- 专项运行 `/tmp/mobileharness-listening-cleanup-focused.log`：UI 12、集成 63、AppWorkflow 19 项通过，包含聆听阶段失败／取消、反馈并行、首 PCM readiness 和反馈参数／PCM。复用既有回归；iOS 原生按压、缓存及会话配置路径不能由 macOS 替身运行代替。
- `./scripts/check.sh` 退出 1：源码／依赖边界、6 项 Python 检查、严格格式通过；UI 106 项、AppWorkflow 131 项通过；集成 1019 项仍有 30 个问题，涉及机械臂时序、Toast 状态、环境逆序断言、播放清理、声源及视觉超时等。全量失败不记为通过。日志 `/tmp/mobileharness-listening-cleanup-check.log`。
- `./scripts/build-ios.sh` 退出 65：MobileHarnessSimulator 在 CoreAIShared 的 arm64／x86_64 编译无法解析 CoreAI，后续三个 scheme 未执行。日志 `/tmp/mobileharness-listening-cleanup-simulator.log`。
- 签名真机构建成功，最终 Bundle 的 25 项 Agent/Skill 资源校验通过。日志 `/tmp/mobileharness-listening-cleanup-device.log`。
- 已安装并启动 iPhone 17 Pro，设备应用清单独立确认 bundleVersion **10192007**（`/tmp/mobileharness-listening-cleanup-installed.json`）；启动日志 `/tmp/mobileharness-listening-cleanup-launch.log`。连续启停、实际提示音／收音及按压预备的设备互斥行为待用户确认，不据此声明已解决系统音频延迟。
- SpeechTypes 错误定义文档已纠正，Audio README 移除重复的历史对照描述，历史失败证据仍保留在本验证日志；本轮不提交，原 89 个已暂存文件的索引保持。
