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

✅ 已迁移全部现有宿主业务输入工厂：AppEnvironmentFact、AppInteractionIntent、ListeningIntent、SpeechCaptureEnded、ProviderDiscoveryIntent、ProviderSettingsIntent、PhotographerCameraIntent、CameraStateObservation、ModelResourceIntent、ModelResourceObservation、ModelResourceHostFailure、MemoryHistoryIntent、AgentSessionControl、AgentTaskInputIntent。领域仅提供 ExternalInputDraft，不创建 AgentInput/InputMetadata；Gateway 的 ExternalInputAdapter 和通用 input 扩展统一创建外部信封。普通 Signal ID/root 由 Gateway 生成，已有业务请求 ID、来源、序号、parent/hops、deadline 和 turn 按契约保留。相机/麦克风/BLE 适配复用同一入口；外部不能生成执行反馈或 Task 授权。

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
