# 外部输入直连 Container 验证

## 范围与基线

验证日期：2026-10-20。分支：`codex/direct-container-input`；container 化基线：`197c53d7`。代码迁移、自动检查、iOS 编译、真实模型和物理设备验收分别记账。原始 Word 和历史验证证据未改写。

## 环境

Swift 6.4、Xcode 27.0（27A266a），macOS arm64。使用 `/Applications/Xcode.app/Contents/Developer` 工具链。未在真机安装或测量性能。

## 自动检查证据

- 通过：独立模块／唯一源码归属／直接输入／执行保护的边界检查；6 项 Python 测试；严格 Swift 格式检查；项目、隐私与 entitlements plist 检查；修改文档的本地引用路径及 diff 格式。
- 通过：定向回归 25 项（23 项集成与 2 项业务流程），覆盖原生相机订阅、感知新鲜度、故障直达、UI 专属 Agent、播放取消、机械跟踪时限、媒体恢复和蓝牙控制独立性。
- 默认 `./scripts/check.sh` 未通过：原生 `cameraNativeMetalDrawStopAndLayerHandoff` 等待真实 GPU 完成超时；IntegrationTests 在全量并发负载下还出现 sound-source 新鲜度、视觉处理启动等待和机械跟踪时限失败。定向运行相关输入用例通过；没有放宽生产新鲜度或时限来掩盖结果。
- 基础迁移阶段使用 `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4 ./scripts/check.sh` 限制测试并发。该阶段结果：999 项 IntegrationTests、130 项 AppWorkflowTests 通过，其他目标通过（真实模型评测为显式跳过）；UITests 116 项中只有上述原生 Metal 用例失败。脚本仍以失败退出，不能将受限并发结果当作默认检查全绿。

原生 Metal 渲染器实现不在本次修改范围内。已观察到失败，但未用基线同环境重跑证明其起因，不将它归类为已确认的既有问题。

## iOS 编译与资源

`./scripts/build-ios.sh` 已执行但未通过：安装的 iOS Simulator SDK 无法提供固定 `coreai-models` 依赖要求的 `CoreAI` 模块。仅构建 arm64 模拟器也出现相同失败；不能标为模拟器编译成功，脚本后续 scheme 未执行。

以下设备 SDK 编译成功，无签名、安装或硬件运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project MobileHarness.xcodeproj -scheme MobileHarness \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64e ONLY_ACTIVE_ARCH=YES build
```

编译保留架构及依赖链接警告；成功仅证明此工具链／设备架构可以编译当前源代码。最终 App 的 Skill 资源检查通过：25 项资源、Core 协议及随 Actions 编译的函数声明。

## 行为覆盖

UI：单消费者、不可用、64 个普通未终态请求（含已接纳）、接纳与完成分离、取消、消费者关闭、根代际和迟到回执；单槽控制请求及满载拒绝；蓝牙普通工作被屏障持有时停止扫描仍可进入执行。

原生输入：独立有界广播、PCM 有序溢出、旧源围栏、只读相机订阅与采集代际、不可变 Float PCM、保留原生序号及布局；本地身份／媒体字段边界与通信注册表不再接受本地来源 schema。执行保护沿用真实 Agent／Gateway／Action 回归，包括权限、资源、旧 owner、取消屏障和真实终态。

以上包含替身、合成媒体与 macOS 测试，不能证明 iOS 原生 UI、真实模型表现或物理安全验收。

## 尚待完成的真机及性能验收

同设备、同配置比较基线和本分支的输入到处理 p50/p95、CPU、分配、常驻／峰值内存、丢帧与 PCM 溢出；分别记录纯原生采集及真实模型结果。当前未测量改善幅度。

覆盖权限拒绝、重复启停、前后台、导航暂停／恢复、切换镜头、源流结束、语音同意／半双工／播放屏障、清理失败、摄影保存／忽略、机械跟踪及停机、设置／历史／资源管理和故障提示。自动测试和设备 SDK 编译均不替代上述验收。

## Agent 自有 UI 输入订阅

UI 子容器已构造注入负责的 Agent，由 Agent start/pause/resume/stop 拥有订阅，AgentApplication 的订阅、类型分发及向 ExecutionSession 转交输入已删除。首页聆听独立归 SpeechPerception；UI 固定输出仍通过身份绑定 Gateway 及 Actions。

专项回归：12 项集成测试（反馈契约失败测试含两个参数案例）和 1 项 UI 回执测试通过。覆盖五个负责角色、真实设置呈现／回滚失败、原生操作完成、普通/控制并行、停止加入、消费者 token 及 UI 代际。还覆盖同一执行回调内暂停／恢复，以及 UI 失活时撤销聆听同意、拒绝等待提交的旧启用请求。

默认 `./scripts/check.sh` 已运行：边界、Python 和严格格式检查通过；原生 Metal 预览及全量并发下的感知新鲜度／机械跟踪时限用例失败（1007 项集成测试，16 个 issue），新增直连 UI 用例通过，不能将默认检查记为通过。

最终以 `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4 ./scripts/check.sh` 复核：1011 项 IntegrationTests、130 项 AppWorkflowTests 及其余目标通过；真实模型评测显式跳过。UITests 共 117 项，只有 `cameraNativeMetalDrawStopAndLayerHandoff` 失败，脚本仍以失败退出。完整日志位于本机 `/tmp/ui-owned-confirmed-check.log`。

前一次受限并发检查还暴露蓝牙恢复测试只等待 `connected`、未等待恢复完成即断言可控制的问题；该测试现等待公开的 `canControl` 就绪后，继续验证无错误、连接隔离及迟到原生错误。未修改蓝牙生产实现或放宽错误断言；最终上述全量运行通过该用例。

`./scripts/build-ios.sh` 已重新执行，仍在模拟器 CoreAI 依赖解析处失败，后续 scheme 未执行；最新生产源码的设备 arm64e SDK 编译成功（无签名／安装），日志位于本机 `/tmp/ui-owned-release-device.log`。没有真机业务或性能测量。

## 感知 Agent 自有原生输入

SpeechPerception 构造注入 AudioCaptureObserving，直接取得当前原生采集代的唯一 PCM 源。VoiceSessionCoordinator／AudioDetectionSession 不取得流或逐帧转交；它们执行采集启停、等待角色结束及合并低频测量。AppleAudioIO／SpatialAudioCapture 共用一份 64 包队列，无重复 PCM 广播。单个长期角色任务就地处理当前包，无角色积压队列或逐包 Task；半双工关闭加入当前包，完整停机取消并加入识别。

VisionPerception 原生入口归角色目录；暂停取消、加入输入及当前推理／发布，恢复建立新订阅。原生帧、PCM 不进入 Gateway，类型化处理上下文和受保护的输出执行保持。

专项覆盖 7 项：唯一消费者、64 包溢出及原错误保留、旧回调隔离、相机暂停恢复、半双工门控仍保留原序号／采集代、采集重启序号归零、慢模型背压和停止／恢复加入已接纳处理。使用合成 PCM、像素缓冲和模型替身。重启用例曾因替身向已结束的旧源发送而超时，修正替身的当前源选择后通过，未放宽生产契约。

本阶段默认 `./scripts/check.sh` 已执行：边界、Python、格式检查及新增直连用例通过；117 项 UI 测试中原生 Metal 用例失败，1014 项集成测试在默认并发下有 27 个 issue（感知新鲜度／视觉等待／机械时限），130 项业务流程测试通过。该次发生在最后一次角色内部任务收敛之前，仅作为阶段证据，不能将默认检查记为通过。

最终源码使用 `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4 ./scripts/check.sh` 复核：1014 项集成测试（包括上述 7 项专项）、130 项业务流程测试及其余目标通过，真实模型评测显式跳过；117 项 UI 测试只有原生 Metal 用例失败，脚本仍失败退出。日志位于本机 `/tmp/native-agent-delivery-check.log`。删除无生产调用的旧广播围栏后，两项旧围栏测试由实际音频源回归替代，原生广播的生产者失败回归保留。

本阶段 `./scripts/build-ios.sh` 再次执行，仍因模拟器 SDK 缺少 CoreAI 模块失败；后续 scheme 未执行。最终源码的设备 arm64e SDK 编译成功（无签名／安装），日志位于本机 `/tmp/native-agent-delivery-device.log`；25 项最终 App 资源及项目 plist 检查通过。真机、真实模型和性能验收仍未执行。

## 语音执行与呈现归入 Actions

VoiceSessionCoordinator、AudioDetectionSession 的实际权限、捕获、播放、停止和语音呈现实现归 Actions/Speech。Agents 的 VoiceAgentSession／AudioDetectionAgentSession 保留真实角色登记、模型上下文和身份绑定输出泵；Actions 通过窄角色生命周期协议连接实际 SpeechPerception，不依赖 Agents 或 Gateway 实现。PCM 仍由角色直接订阅。频谱由 Actions/UI 的呈现服务验证测量、采集句柄和 UI 根代际后提交。

音频控制与观察分离为跨平台 AudioCaptureControlling／AudioCaptureObserving，AppleAudioIO 继续实现实际 iOS 驱动。检测取消立即启动唯一关闭任务并加入原生停止／角色关闭；工厂迟到或启动中报告失败均先清理，不能随后启动硬件。完整语音停止还释放音频作用域，半双工暂停保留该作用域用于恢复。

新增 7 项集成回归覆盖频谱旧采集／根失效／非法值、实际角色通过执行协议维持同意与 revision 权限，以及实际 Actions 检测服务的取消、中断、权限拒绝、迟到工厂和已报告启动失败。采集控制端、像素、模型使用明确替身；这些结果不证明系统权限弹窗、声音、动画渲染或真机表现。

最终源码以 `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4 ./scripts/check.sh` 检查：1021 项集成测试、130 项业务流程测试及其余目标通过，真实模型评测显式跳过；117 项 UI 测试只有 `cameraNativeMetalDrawStopAndLayerHandoff` 失败。脚本仍失败退出，日志为本机 `/tmp/action-execution-delivery-check.log`。边界、Python、严格格式、文档引用、diff 及 plist 检查通过。

本阶段默认 `./scripts/check.sh` 的阶段运行（跨平台检测取消收尾之前）有 1017 项集成测试、24 个 issue，涉及全量并发下的感知新鲜度／视觉等待／机械时限；业务流程 130 项通过，Metal 用例仍失败。不将受限并发结果描述为默认检查全绿，也未放宽生产时限。

`./scripts/build-ios.sh` 已执行，仍在 Simulator 的 CoreAI 依赖处失败，后续 scheme 未执行。最终设备 arm64e SDK 编译成功（无签名／安装），日志为本机 `/tmp/action-execution-delivery-device.log`；25 项最终 App 资源验证通过。原生系统与真机／性能验收仍待执行。

## 2026-10-20 — 完整收尾实现与验收进度

代码实现覆盖语音手势和检测的直接类型化接纳、完整历史受保护读取、角色自有相机／资源订阅及 Actions 业务呈现。移除历史全局数据暂存和重复只转交接口；完整读取的最多四个任务只代表实际工作和取消加入。内部执行附件只允许本地无模型轮次的调用，保留 Gateway 身份、权限、资源和取消校验。检测的原生控制在 Actions，角色创建与模型输入消费在 Agents；检测原始错误与清理错误均保留。页面取消绑定实际处理任务，消费者加入取消后仍可处理后续请求。

新增专项覆盖检测实际停止加入、清理失败、完整读取四任务上限和根停止、按压手势不授予采集同意、UI 取消加入后继续处理。五个专项回归通过，日志 `/tmp/direct-cancel-focused.log`。不将替身采集或受保护的测试函数称为真机业务验收。

默认检查分普通并发阶段和实际时钟／原生窗口阶段；两阶段均执行且任一失败返回非零，不设置全局并发宽度，不改变生产期限。首次阶段与 Xcode 编译同时运行，普通 UI 115 项和业务流程 130 项通过，989 项集成测试出现 40 个 issue（包括超时、新鲜度和诊断呈现），不能记为通过。须在构建结束、宿主空闲后复核；并发编译影响只是待复核的解释，不能替代结果。

原生窗口重试 `/tmp/direct-native-visible-retry.log`：页面销毁加入通过；Metal 用例未满足可见窗口前提（isVisible=true，occlusion=8192，无 visible 位，application.isActive=false），失败而非跳过。正在验证命令行宿主的 AppKit 事件分发，未修改生产 Metal renderer 来迎合测试。

用户确认连接解锁后，设备工具识别 iPhone 17 Pro / iOS 27.0.1，Device Hub 可读取实际屏幕。设备上已有 Gemma4、MossTTSNano、Nemotron、Silero、YOLOPose 安装目录；目录存在不等于当前模型调用通过。用户明确机械臂尚未准备好，先进行其余验收；本轮不执行机械臂动作。

Simulator 构建使用显式变体排除不支持该 SDK 的默认 Gemma 后端，其不可用状态仍明确报告，不生成替身成功。完整四 scheme、签名设备构建、实际安装／业务及性能对照结果待后续记录。采样默认关闭，只有 `-direct-input-measurements` 记录接纳／完成年龄，无媒体内容；尚无性能提升实测结论。

### 后续验证事实

- `/tmp/direct-final-ios.log`：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个 scheme 均构建成功，最终 App 的 25 项资源验证通过。此版本随后仅有 HomeEffectsBindings 身份投影合并，最终构建仍需补证。
- `/tmp/direct-final-device.log`：iPhone 17 Pro 的 Debug arm64 签名构建成功；`/tmp/direct-device-install.log` 安装成功，`/tmp/direct-device-launch.log` 启动成功。原始应用数据保留。不能将这份构建当作之后改动的验证。
- `/tmp/direct-native-event-pump.log` 与 `/tmp/direct-idle-check.log`：原生 Metal 真实绘制／停止／交接及导航根销毁两项通过。命令行宿主分发 AppKit 事件后满足可见窗口前提，不改生产 renderer。窗口创建后立即注册清理，失败前提同样关闭窗口。
- 宿主空闲重跑 `/tmp/direct-idle-check.log`：普通 UI 115、业务流程 130、实时输入 37、原生 UI 2 项通过；989 项集成测试仍有 12 个 issue（机械实际时限、轮次期限及 Toast 到期等待），说明并行编译不是唯一解释。统一将实际机械反馈/准入、轮次、Signal SLA、根 UI 到期及原生输入生命周期的异步回归归入 LiveRuntimeTests，用语法树迁移测试声明，保留全部断言和用例内并发。
- `/tmp/direct-runtime-grouped-check.log` 的普通阶段 809 项只有监听同意／回复占用回归出现 4 个 issue，其三秒真实轮次期限随后也归入 LiveRuntimeTests。完整最终运行结果继续跟踪，不将阶段运行描述为全绿。
- 用户授权临时隔离检出基线，实际位置为 `/Users/devil/.codex/worktrees/direct-input-baseline/MobileHarness`，基于 197c53d7；只回补可选 OS signpost，保留旧输入链路。基线尚未构建或采样。
- 用户要求保持现有云配置，仅用合成文本验收。相机仅做本地预览／保存／忽略，不发起云端图片理解；不改本地/云端选择。
- 真机 UI 已实际执行十秒音频检测：显示“空间采集 · 4 声道”“内置麦克风”“支持”“音频正常”，自动停止并显示“检测完成”。这是原生采集和角色处理的证据，不证明 ASR、LLM、TTS 或性能。
- Instruments 按二进制名／旧 PID 附加失败；使用 bundle ID 启动后成功写出 `/tmp/direct-current-launch-pilot.trace`（20 秒启动试录，含 os_signpost 和 Activity Monitor）。此试录没有受控输入，不能算作性能对照。
- 真机出现一次 invalidPayload 提示，相机开启后的黑色预览尚未确认原因，正在定位；完整业务验收仍未通过。

### 全量检查与后续真机定位

`/tmp/direct-final-verified-check.log` 已确认退出 0：集成 1026 项（普通并发 808、LiveRuntime 串行 218）、业务流程 130、UI 117（普通 115、原生 2）通过；其他目标、边界、严格格式和 plist 检查通过。真实模型 opt-in 测试显式跳过。原生测试验证真实 Metal draw/stop/layer handoff 与页面销毁加入；不以此代替 iPhone 验收。

真机已连接并解锁。用户确认镜头无遮挡，且本机也黑屏；YOLO 帧率有更新，仍不能认定预览通过。启动 `invalidPayload` 提示可复现，切镜头曾出现 UIRequestError；继续定位。机械臂未准备好，按用户指示暂缓其物理验收。云模型配置保持，仅使用合成文本进行云端验收。

### 基线构建与设备连接中断

基线 `197c53d7` 在批准的隔离 worktree 中完成 Debug arm64 签名构建，日志 `/tmp/direct-baseline-pinned-device.log`，退出 0。仅加入 opt-in 无内容的原生接纳计时及同一 DEBUG 合成文本重试入口；恢复并锁定原提交 Package.resolved。首次共用依赖检出造成编译输入冲突，之后依赖完全隔离；自动解析曾更新基线锁定文件，已恢复并锁定版本重建成功。失败或取消的构建不作为通过证据。

基线安装失败（CoreDeviceError 4016）；Device Hub 和 devicectl 均确认设备 unavailable，已请求用户重新连接解锁。基线未安装，未开始正式同设备对照，设备上仍是先前安装的当前版本。

先前安装版本的 DEBUG 合成文本诊断真实返回算术答案 `4`，总耗时 0.573683 秒，日志 `/tmp/direct-current-model-console.log`；语音识别仅准备，不采集麦克风。这只是配置模型能力调用，不是 Agent/Actions 全语音、照片或完整业务回归，也不是完整冷/热统计。

最终构建复核中临时移出生成缓存以减少开发工具递归扫描，缓存与源码均保留。编译插件缓存含绝对路径，第一次外部缓存构建找不到 SwiftSyntax 模块而失败，已补回临时路径映射后重试。完成后须恢复原缓存位置。

### 最后源码的构建复核

`/tmp/direct-current-linked-cache-ios.log` 确认 `build-ios.sh` 退出 0，四个 Simulator scheme 全部成功，最终资源验证通过。使用可选 `MOBILEHARNESS_SIMULATOR_DERIVED_DATA` 指定缓存；App 配置及依赖锁定文件保持。随后手势去重的最后源码以 `/tmp/direct-final-gesture-simulator.log` 再次完成 Simulator App 编译，退出 0。

`/tmp/direct-final-gesture-device.log` 确认最后源码 Debug arm64 签名 iPhoneOS SDK 构建成功，退出 0，使用 generic iOS destination；设备连接中断，因此不是安装或真机运行通过。最终 Device/Simulator App 的 25 项资源分别验证通过。

已恢复原 `build/`、`.build/` 实体目录；外部临时缓存路径保留反向链接，维持编译插件的绝对引用，新生成索引缓存另行保留。源码、原缓存内容及本地配置均未删除。最终自动检查日志为 `/tmp/direct-final-restored-check.log`，结果须在完成后记录。

源码核对修正 DragGesture 每次移动重复提交 press(true)：只在按压状态变化提交，离开页面重置本地状态。未改控制容量、长按触发或业务策略；已编译，不认定其已经解决真机错误，实际触控与启动拒绝仍待定位。

边界检查移除 Gateway 退役设备适配例外，并在 Agents/Gateway 同时禁止旧适配类型；本地领域值的断言改为 ProcessingContext 接纳。专项边界检查通过，受影响文档 562 个相对链接均有效，diff 格式检查通过。

### 后续失败与锁屏限制

`/tmp/direct-final-restored-check.log` 退出 1：普通 UI 115 项中 cameraPoseExpiresWithoutRemovingLiveVideo 失败。等待骨架过期后恢复执行已约 1.035 秒，视频也已超过 750 毫秒期限；断言失败事实保留。普通集成 808、业务流程 130、原生窗口 2 及串行集成 218 项通过。不能将此轮记为全绿。

相机五个真实期限及三个根／媒体生命周期用例移入既有 NativePresentationTests，iOS halo 停止用例也归此阶段；方法体和断言保持。macOS UI 总数仍为 117（普通 107、串行 10）。未设置全局并发宽度，未放宽生产期限或等待上限，调整后的结果待复核。

按压去重最终使用 GestureState 自动在抬起／取消时复位。诊断文本改用独立 `-direct-input-diagnostics` 开关；`-direct-input-measurements` 只保留计时，避免额外诊断输出污染基线对照。最后这两项微调后的 SDK 复核尚未完成。

桌面工具明确返回 Mac 已锁定且无法自动解锁，要求用户手动解锁；iPhone 仍 unavailable。SDK 构建客户端采样停在 NSFileCoordinator 项目递归读取等待，已停止客户端、恢复缓存目录，并请求用户解锁 Mac、连接解锁 iPhone。不尝试绕过锁屏。

继续执行不需要可见窗口的普通测试及串行媒体／执行测试，日志 `/tmp/direct-headless-ordinary.log`、`/tmp/direct-headless-runtime.log`；明确排除两个需要可见窗口的原生用例。此阶段不是 `check.sh` 的完整通过证据，原生窗口、最终 SDK、真机黑屏／拒绝及同设备性能对照均待恢复环境后完成。

无窗口复核已确认退出 0：普通 UI 107、串行媒体 UI 8、普通集成 808、串行集成 218、业务流程 130 及其余测试目标通过；真实模型 opt-in 用例仍显式跳过。集成总数 1026，已复核 UI 115；两个可见窗口用例待解锁后补齐。最后的两个 SDK 构建客户端在项目读取锁等待中被停止，未获得最后微调的 SDK 结果；此前四个 Simulator scheme 和签名 Device SDK 成功证据不替代这次复核。

最后静态复核以失败即停止的命令执行并退出 0：模块边界、6 项离线 Python 测试、全量严格 Swift 格式、项目／隐私／权限 plist、两份检查脚本语法及 diff 格式通过。日志 `/tmp/direct-final-boundaries-confirmed.log`、`/tmp/direct-final-python-confirmed.log`、`/tmp/direct-final-format-confirmed.log`、`/tmp/direct-final-plist-confirmed.log`。`build/` 与 `.build/` 已恢复为原位置的实体目录，无等待中的构建客户端；基线 worktree 保留供连接恢复后继续对照。真机问题及性能结论仍未关闭。

### 恢复连接后的复核与直接入口修正

首次恢复检查 `/tmp/direct-resumed-check.log` 退出 1：普通集成 808 项中 `hostCancelTerminatesActiveInferenceBeforeQueuedCancellationAndOtherSessionReply` 捕获 ConversationHistoryError.conflict；原生／串行 UI 10 项及 LiveRuntime 218 项通过。专项单独运行原取消测试通过，故不把单独成功覆盖全量失败。

用户文本接纳原先先 readCurrent 再 begin，中间在途回复可改变 read token。新增 ConversationHistoryStore.admitUserInput，在同一写入 gate 中选择当前会话、建立 awaitingModel 记录并执行实际 checkpoint；模型请求的 begin 仍严格校验精确 token，无副作用重试。新增回归验证回复更新保留、用户接纳、重复拒绝及旧 token 拒绝。

解锁后真机仍复现启动资源故障 `agents.resources observe: presented("invalidPayload")`。实际 artifact revision 订阅把资源事实包装为只允许 user 来源的 ModelResourceIntent，因 model.resources 来源被拒绝。改为已有 ModelResourceObservation.changed 直接处理，保留来源、单调序号及 Gateway/Actions 呈现。新增回归从真实角色拥有的 revision 订阅入口驱动两次更新，不只直接调用 observeResource。

专项历史／取消 5 项、资源观察 3 项通过。修正后完整 `./scripts/check.sh` `/tmp/direct-resumed-fixed-check.log` 退出 0：普通集成 810、串行集成 218，总计 1028；业务流程 130；普通 UI 107、串行／原生 UI 10，总计 117；边界、Python、严格格式与 plist 均通过。真实模型 opt-in 用例仍显式跳过，此结果不证明修正版已安装或真机通过。

设备最初已连接但仍锁定，首次启动 `/tmp/direct-resumed-launch-console.log` 明确因 Locked 失败；用户随后解锁成功，原已安装版本启动并本地复现黑色预览，YOLO 约 4.5–4.7 FPS。此次未进行云端图片／音频请求，观察后终止自己启动的应用进程结束采集。

批准的基线 197c53d7 成功安装并本地复现相同黑色预览，YOLO 约 4.4–4.6 FPS；这是故障是否存在的对照，不是受控性能数据，不推断性能改进。校正基线计时补丁为每帧仅在 receive 接纳处一次 Camera.Admit，删除 infer/emit 的重复同名采样。`/tmp/direct-resumed-baseline-signed.log` 退出 0，基线重新签名构建成功；首次重建未传本机签名团队而失败的日志 `/tmp/direct-resumed-baseline-rebuild.log` 保留，不作为成功证据。未改基线 Package.resolved 或旧输入链路。

最终修正版 iPhoneOS 构建 `/tmp/direct-resumed-fixed-device.log` 仍停在项目协调读取，尚未开始编译；采样 `/tmp/direct-resumed-build-sample.txt` 显示 NSFileCoordinator 等待，Xcode 桌面调用返回 AppleEvent timeout。已请求用户保存并退出 Xcode。基线项目可构建不等于当前项目锁已解除。

已结束基线应用进程并恢复安装最近可用的当前分支签名包，日志 `/tmp/direct-resumed-current-restore.log` 成功；该包早于上述两个代码修正，不将恢复安装记为修正版交付。云配置与应用数据保留，未运行机械臂。黑屏根因、修正版设备／Simulator SDK、完整业务及正式性能对照仍未完成。

资源订阅恢复补验：角色从最后已接纳序号递增，新订阅初始 revision 不会重用旧序号。覆盖两次更新、pause/resume 后新源首条更新的专项测试通过，日志 `/tmp/direct-resumed-resource-lifecycle.log`；该细化之后的完整检查继续复核。

最终序号恢复细化后的完整复核 `/tmp/direct-resumed-lifecycle-final-check.log` 已确认退出 0：集成 1028（普通 810＋串行 218）、业务流程 130、UI 117（普通 107＋串行／原生 10）通过；其他目标、模块边界、离线 Python、严格格式及 plist 通过，真实模型 opt-in 用例显式跳过。

`./scripts/build-ios.sh` 实际重试日志 `/tmp/direct-resumed-simulator.log` 停在第一个 scheme 的项目读取，采样 `/tmp/direct-resumed-simulator-sample.txt` 同样证实 NSFileCoordinator 等待；设备与模拟器两个等待客户端均已停止，退出 143，不能记录为构建通过。无遗留 xcodebuild／测试／设备 console 客户端。

恢复安装的当前包诊断日志 `/tmp/direct-resumed-restored-diagnostics.log` 明确输出 `DIRECT_INPUT_REJECT role=ApplicationControl source=model.resources contract=model.resource.intent`，与源代码修正一致。首个空表面 GPU completed 不能证明实时视频已展示；本轮未定位黑屏根因。结束自己启动的应用进程，设备上保留最近可用的当前分支包，而非基线；本轮两处源码修正仍待解除项目读取锁后构建安装。未录制正式性能轨迹，也未产生提升幅度结论。

### 修正版隔离构建与安装复核（2026-10-20）

用户明确批准包含当前未提交改动的临时隔离构建后，创建并附加 `/Users/devil/.codex/worktrees/direct-input-device-fix/MobileHarness`。从当前分支 HEAD 应用完整 binary diff 并复制非忽略未跟踪文件，未提交代码、未改旧性能基线。构建前逐文件核对 1114 个源码、配置及文档；构建后复核其中 685 个非 Markdown、非 docs 的输入与原工作区和快照 SHA-256 全部一致。快照清单 `/tmp/direct-input-device-fix-source-manifest.json`。

iPhoneOS Debug 签名构建 `/tmp/direct-resource-fix-isolated-device.log` 退出 0；锁定原 Package.resolved，swift-collections 1.7.0、Jinja 2.5.1，25 项 App 资源验证通过 `/tmp/direct-resource-fix-resources.log`。修正版安装 `/tmp/direct-resource-fix-install.log` 退出 0，bundle `dev.mobileharness.app`，安装数据库序号 4436。此安装确实包含资源 observation 与历史接纳两处修正，取代此前仅恢复旧包的交付状态。

隔离目录执行 `./scripts/build-ios.sh` 后检测到自动依赖解析改变了隔离项目的 workspace Package.resolved，因此停止该次构建并恢复两份锁定文件；原工作区锁定文件未改。随后按脚本同顺序执行 MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero，附加禁止自动解析、只使用锁定版本和跳过包更新的参数，四个 scheme 均成功，App 25 项资源验证通过，日志 `/tmp/direct-resource-fix-pinned-ios.log`，退出 0。此结果是锁定依赖的脚本等价构建，不把停止的脚本运行记为通过。构建后原工作区与隔离目录的两份 Package.resolved 逐字节一致。

设备解锁后修正版启动成功，诊断日志 `/tmp/direct-resource-fix-startup-console.log` 未出现 DIRECT_INPUT_REJECT；通过 Device Hub Home 进入后台并激活本应用后观察到前台页面，未看到原错误弹窗，但执行记录尚未完成可靠核对，不能只凭无诊断输出认定验收通过。

投屏业务坐标点击出现偏移，一次意外显示“我在听”；立即通过设备调试器终止自己启动的进程（PID 1945，SIGTERM 成功），不再坐标操作业务控件。不能将本轮描述为全程未触发聆听，也不能从当前有限日志推断有无实际音频或网络请求。随后重新启动修正版，仅观察启动／生命周期诊断，日志 `/tmp/direct-resource-fix-lifecycle-console.log`；请用户在本机核对 Agent 异常记录并手动两次前后台切换，结果待补。相机预览黑屏、完整业务回归、机械臂与正式同设备性能对照仍未完成。

本机确认结果：用户按上述请求检查「执行记录 → Agent → 异常」并进行两次后台回前台后，回复“没有出现新错误”。结合真实角色资源订阅／暂停恢复回归、完整自动检查、已安装修正版及诊断日志，本次启动和前台恢复的 `agents.resources / invalidPayload` 故障验收通过。真机交互核对由用户执行，此结论不扩展至相机黑屏、全业务或性能验收。

### Support 职责与旧宿主协议收敛（2026-10-21）

保留原分支和既有未提交改动，仅使用既有源码目录。Support 根 Swift 文件由 17 个减至 10 个，递归由 90 个减至 79 个（其中 51 个仍属于独立 AgentCore）；角色专用文件归所属角色，跨角色机制与应用装配留在 Support。Agents 总体源码减少约 700 行，不将文件移动本身计为代码删除。

- 四个 ExecutionSession 分别属于 Assistant、ApplicationControl、Memory、Photographer，只拥有注册、身份绑定输出及清理；Photographer 保留最多 8 项的跟踪队列。移除宿主请求表、固定输出步数、结果等待器、旧取消握手及无调用 Assistant 入口。
- ApplicationControl 拥有 ResourceObservationSession；Memory 拥有 HistoryExecutionPreview；VisionPerception 拥有 VisionAgentSession 和 VisionPipelineWorkflow。视觉会话仅注入 PoseCapability、CameraFrameObserving 及其角色运行装配。
- SpeechPerception 拥有语音与诊断角色装配。VoiceRuntimeDependencies 与 VoiceAgentSession 同文件，诊断公共会话与诊断角色装配同文件；NativeFailureClassification 与 ContainerFailureChannel 同文件。
- 资源、设置、历史、摄影及设备请求夹具通过真实 UI Container 提交并等待回执；夹具便捷方法不重建业务路由或执行协议。独立的暂存权限、Action 参数及角色读取容量仍在其所属边界测试。页面取消和重叠请求断言遵守当前 UI 取消加入／有界串行排队契约。
- 偏好失败呈现再次失败时，保留执行及呈现原因，不根据字符串投影为单一选择错误；删除失去调用的旧错误投影。缺失返回契约仍在原生效果前拒绝，失败呈现不重试。

专项回归 `/tmp/support-cleanup-regression.log` 退出 0，包含 185 项集成／串行相关测试、43 项相关 UI 测试及其他匹配目标；真实模型 opt-in 仍显式跳过。过程中旧断言的暂停／排队差异和测试编译错误曾失败，均已修正后重跑，不将失败轮次记为通过。

`./scripts/build-ios.sh` 在已批准的临时 worktree 中运行，使用当前工作区逐文件核验的源码。初次构建因拆分文件使用了装配层 ModelVisionProviding 类型而失败；会话改为真正所需的 PoseCapability 和 CameraFrameObserving 后，四个 Simulator scheme 全部成功、25 项 App 资源验证通过。工程引用收尾后再次执行完整脚本，最终日志 `/tmp/support-cleanup-ios.log`，退出 0。构建脚本显式只使用 Package.resolved，禁止自动更新；两份锁定文件与原工作区一致。683 个非文档构建输入的 SHA-256 在原工作区、构建快照与清单间一致，清单 `/tmp/support-cleanup-source-manifest.json`。

23 份相关 README 的本地路径及代码围栏检查通过，共 43 个 Mermaid 图；没有完整图形渲染验收。边界检查已禁止角色宿主恢复旧业务入口、请求表／等待器及角色专用文件回流 Support。完整 `./scripts/check.sh` 日志 `/tmp/support-cleanup-check.log`，退出 0：集成 1028（普通 810＋串行 218）、业务流程 130、UI 117（普通 107＋串行／原生 10）通过，其他目标、6 项离线 Python、严格格式、边界及 plist 均通过；真实模型 opt-in 仍显式跳过。

最后清除工程中指向已删除 ResourceObservationWorkflow 的残余引用；首次编辑误删了同一行的组结束符，plist 失败，立即修正后 plist 与工程源码引用检查通过，没有缺失的 Swift 文件引用。最终边界检查 `/tmp/support-cleanup-final-boundaries.log` 退出 0，随后上述四目标完整构建退出 0。收尾没有修改 Swift 源码，不重复已通过的运行时测试。

本轮未安装本次结构整理版本到 iPhone，不将此前资源故障修正版的人工确认扩大为本次结构整理的真机验收。原生实时相机黑屏、完整业务与物理机械臂、正式同设备性能对照仍单独跟踪。

## 原生输入唯一入口审计（2026-10-21）

### 实现范围

- SpeechPerception 的通用 AgentInput 不再接纳 audio；取消其 4096 包／8,388,608 scalar samples／30 秒补充积压队列及 worker。原生源的 64 包 FIFO 加当前包是唯一原始 PCM 输入缓冲；SpeechRecognitionTurn 的有界 VAD 已提交模型工作／冷初始化前缀仍有独立职责。
- VisionPerception 的通用 AgentInput 不再接纳 image；CameraFrame 在角色内完成接纳。运动分析直接使用 gray64，模型和输出保留同一原生 pixel buffer；取消 RGB 降采样、SampledImageAttachment，以及 Signal 预处理器中的不可达媒体分支。原生过期拒绝会计入诊断，不占用帧槽或推进序号。
- Core.Input 只保留 Float PCM 和不透明图像附件；取消字节 PCM 存储／构造／转换别名、RGB 构造、单分支内容包装及 ImageAttachment／ImageValueAttachment 泛型壳；附件直接持有 CameraFrame。合成字节转换与原生帧生成属于 IntegrationTests 夹具。
- SignalOrigin 只保留 local／agent／runtime；取消 external 历史解码来源。领域 input 工厂不暴露未使用的 sequence 参数。
- 订阅取消／加入、请求回执、Gateway 权限／租约／结果归属、Actions 能力适配、容器失败聚合保留实际职责；不存在新建的输入转发模块。四基础模块独立。

### 验证

- 定向 6 项媒体回归及 30 项原生输入运行回归通过，包括冷启动有序前缀、恢复后下一轮、源代际、半双工、原生附件身份、同帧校验、过期预算和通用入口拒绝；均使用合成 PCM／图片及模型替身。
- 最终 `./scripts/build-ios.sh` 四个 Simulator scheme 成功。使用已获批准的隔离检出，与当前工作区同步校验；工具链 `/Applications/Xcode.app/Contents/Developer`，25 项打包 Skill 资源校验通过。日志 `/tmp/direct-native-only-ios-final-snapshot.log`，源码清单 `/tmp/direct-native-only-source-manifest.json`。
- 最终 `./scripts/check.sh` 退出 0，但不能将退出码当作全部目标完成：IntegrationTests 1,029 项（普通 808＋串行 221）、AppWorkflowTests 130 项、普通 UITests 107 项及其他目标有完整通过记录；6 项 Python、独立模块／直接输入边界、严格 Swift 格式及项目／隐私／entitlements 检查通过。真实模型和物理串口用例按契约显式跳过，不计为设备通过。最终日志 `/tmp/direct-native-only-check-verified.log`。
- ❌ NativePresentationTests 在 cameraNativeMetalDrawStopAndLayerHandoff 启动后进程退出 0，没有用例／组完成记录；独立重跑同样复现，日志 `/tmp/direct-native-only-native-presentation.log`。该项未验证，不能宣称通过，也没有证据归因为本轮输入修改。另行排除这一项运行其余 9 项均有完整通过记录，日志 `/tmp/direct-native-only-native-presentation-rest.log`；UI 合计确认 116 项通过、1 项未验证。未修改生产 Metal 渲染器或放宽测试断言。
- 首轮检查发现媒体测试仍使用通用入口／RGB 模型夹具，以及合成突发依赖无原生单调时钟的假设；普通集成阶段 812 项中报告六个 issue，串行阶段为修订中断。已改为原生媒体夹具；发布／替换／终态用例显式注入近零采样间隔，实际 cadence／freshness 用例保持默认策略。初次日志 `/tmp/direct-native-only-check.log`。后续全并发又暴露共享姿态用例对真实捕获时钟的依赖；共享投递、慢订阅、终态保留和拒绝订阅四项归入既有 LiveRuntimeTests 串行组，实际 native cadence／freshness 仍使用生产预算。中间两次串行阶段为最终快照重跑而中断，没有作为全量通过证据。没有放宽生产采样与新鲜度预算。
- 本轮没有重新安装或执行 iPhone、真实云模型、实际相机／麦克风或机械臂验收；不据自动测试声称真机预览黑屏修复或性能提升。

## 资源观察通知精简（2026-10-21）

- ResourceObservationSession 仅发送无参数 changed 通知，删除无消费用途的本地 sequence、溢出失败和回调参数。ApplicationControl 的 observationSequence 仍负责处理顺序，订阅 epoch、前后台取消／加入、源结束／错误投递均保持。
- 定向三项回归通过：资源通知与停止加入、UI pause/resume 重订阅、artifact 变化来源及角色刷新顺序。测试使用合成流与业务替身，不代表实际下载或设备验收。日志 `/tmp/resource-observation-simplify-focused-final.log`。
- `./scripts/build-ios.sh` 四个 Simulator scheme 构建成功，25 项 Skill 资源校验通过；使用已批准的隔离检出同步当前源码。日志 `/tmp/resource-observation-simplify-ios.log`。
- `./scripts/check.sh` 退出 0，集成 1,029 项（普通 808＋串行 221）、业务流程 130 项及边界／格式／Python／plist 检查通过。日志 `/tmp/resource-observation-simplify-check.log`。
- 原生 Metal 窗口用例仍在启动后缺少完成记录，不能计为通过；排除该项独立重跑，其余原生呈现 9 项通过，结合普通 UI 107 项，确认 UI 116 项通过、1 项未验证。日志 `/tmp/resource-observation-simplify-native-rest.log`。本轮未做真机或真实模型验收。

## Support 全面职责整理（2026-10-22）

### 实现与边界

- 删除未调用的 historyProjection、AssistantControl 兼容别名、未启用的 Chat 父提交接收等待表，以及没有 payload 的 InputKind.video／binary。保留 Assistant 向固定 Memory 发送 agent.parentCommitted、Memory 接纳该消息及 Task 结果关联。
- AgentTaskContextState／恢复校验归固定 Task 协调文件；AgentStateContext 独立归 Context。Communication 仅保留跨角色值、角色 ID 和真实消息 schema；设置、资源、环境、摄影、聆听、历史及会话控制类型归各自既有角色目录。
- VoiceInteractionSession 归 SpeechPerception；ApplicationEnvironmentInputs 归 ApplicationControl，保存最多五类待处理最新事实，拥有来源序号、原始失败上报和取消加入。AgentApplication 仅接线；视觉会话失败进入既有容器故障聚合，业务展示仍由角色通过 Actions 决定。
- App/Composition 的 ApplicationPresentation 组合已有 UI 页面和展示协议，内部会话展示对象按语音会话实例复用；只引用现有状态／请求端口，不订阅或转发业务输入。UI、PlatformKit、ModelKit、Storage 不依赖上层业务模块。
- 工程引用、SwiftPM 排除列表、现行 README／图及边界检查同步归属；没有新建目录、模块、第三方依赖或持久化格式。旧设计和历史验证证据保留。

### 验证方法与限制

新增三个合成环境输入回归，覆盖同类合并、投递失败后的继续处理，以及取消并等待活动任务退出。测试不采集相机、语音或调用真实云模型。本轮未进行 iPhone、真实模型、机械臂或性能验收，不据自动检查声称修复 iPhone 黑屏或提高性能。

### 最终结果

- `./scripts/check.sh` 退出 0：集成 1,029 项（普通 808＋串行运行时 221）、业务流程 133 项、UI 117 项（普通 107＋原生窗口 10）均有完整通过记录；其他测试目标、6 项 Python 检查及项目／隐私／entitlements 检查通过。真实模型／物理设备用例按原契约显式跳过，不能计为设备通过。日志 `/tmp/support-ownership-check.log`。
- 本次 cameraNativeMetalDrawStopAndLayerHandoff 明确通过，NativePresentationTests 全组 10 项有终态，补齐本次快照的宿主窗口验证；此前退出 0 却没有完成记录的历史事实保持原样。不将此结果归因为生产 Metal 修复，也不替代 iPhone 预览验收。
- `./scripts/build-ios.sh` 四个 Simulator scheme 成功，25 项 Skill 资源校验通过。完整 Xcode 工具链、已批准的隔离检出同步当前源文件；最终构建日志 `/tmp/support-ownership-ios-verified.log`，682 个源码／配置／工程／脚本文件与同步清单校验一致。中间 iOS 构建发现新增 lazy 属性的隔离类型推断失败，改为显式属性类型及工厂方法后通过；初次严格格式检查拒绝跨模块 retroactive conformance，改为 App 自有会话展示对象后通过，没有关闭检查规则。
- 最终独立边界检查退出 0，额外校验文件唯一归属、退役实现、App 页面构造边界及固定 Memory 提交确认；日志 `/tmp/support-ownership-boundaries-final.log`。最终严格 Swift 格式检查退出 0，14 份当前设计 README 的本地链接及 `git diff --check` 通过。构建及完整测试启动后只有 Package 对 App 专用文件的排除声明和结构检查增补；后续四目标构建、最终格式和独立边界检查均覆盖这些收尾变化，运行时 Swift 源码未再变更。
