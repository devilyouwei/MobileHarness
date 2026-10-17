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
