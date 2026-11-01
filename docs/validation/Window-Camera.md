# Window / Camera 验证

## 2026-11-01 录像音频交接与照片方向回归

用户在2026110110真机反馈：录像启动报告PlatformError busy，取景框直立而拍后缩略图横转。代码定位到聆听暂停仅停止麦克风采样，未释放AudioContainer的voice owner；成片使用重力captureRotation，与窗口界面方向不一致。修复加入完整音频I/O停止与清理失败检查、播放准入围栏及恢复后的事件重订阅；照片和录像在执行时冻结实际窗口角度，原生输出连接验证并写入方向，未改动YOLO重力坐标。

专项验证通过：1项UI方向测试、4项集成测试函数（其中音频交接含成功／取消／清理失败3个参数案例），日志`/tmp/camera-fixes-targeted.log`。合成帧覆盖前后传感器参考、四种窗口方向与四种重力方向，原生录制端口为受控替身。它们不证明真实麦克风收音或JPEG／movie结果。

四个iOS构建全部通过：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero；包内25项资源通过（`/tmp/camera-fixes-ios.log`）。真机构建通过（`/tmp/camera-fixes-device.log`），严格签名与25项资源校验通过。build2026110111原位安装到iPhone17 Pro，安装流水5348；系统应用清单确认0.1.0／2026110111，并成功启动（`/tmp/camera-fixes-install.log`、`/tmp/camera-fixes-launch.log`）。未卸载或删除用户数据。

完整check.sh退出0：边界检查、Python6、严格Swift格式、各产品测试、952项集成测试（63.794秒）、225项实时回归（204.162秒）和plist全部通过（`/tmp/camera-fixes-check.log`）。修改文档的本地链接与git diff --check通过。已请求真机确认聆听开启时的10秒有声录像／停止回放，以及相同持机姿态下的照片方向；尚未收到结果，安装／启动不能替代这两项验收。

## 2026-11-01 拍照增强与有声录像

用户确认倒计时／取消、闪光灯、变焦，以及带声音录像并暂停聆听。实现保持背景Vision与Camera窗口独立需求、单Foundation视频流；录像使用原生开始／终态回执、最长600秒／512MiB，关闭与后台停止封装，最小化继续录制。相册增加视频回放、导出和删除。

完整`check.sh`退出0：边界、Python6、严格Swift格式、各产品测试、950项集成测试（63.972秒）、225项实时回归（204.486秒）及plist通过，日志`/tmp/camera-enhance-check.log`。新增专项验证参数拒绝、单调倒计时及取消、录像停止／音频恢复、后台文件保留、幂等保存、文件所有权／配额／禁止图片读取和真实Photographer→Gateway→Action链。最后追加的启动取消及快速前后台聆听围栏通过7项专项（`/tmp/camera-enhance-final-targeted.log`）；领域录像与媒体内容使用明确替身，不代表原生编码／收音验收。

提示词实测base24971、Photography35246 UTF-8字节，分别在25000／36000预算内；Photography新增六项Action与录制流程，Basic常驻Actions未增加。早期iOS构建暴露SwiftUI方法引用歧义，已改为明确闭包；边界检查发现Video声明与文件归属不符，已按规范移到VideoActions.swift，并将AVKit仅允许在本地播放组件中。后续构建结果记录如下。

最终源码的四个iOS构建全部通过：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero，模拟器包25项资源校验通过（`/tmp/camera-enhance-ios-final.log`）。

真机最终构建通过（`/tmp/camera-enhance-device-final.log`），严格签名及25项资源校验通过；build2026110110已原位安装到iPhone17 Pro，安装流水5340，系统应用清单确认版本0.1.0／2026110110（`/tmp/camera-enhance-install.log`）。未卸载或清除App数据。安装后尝试启动被iPhone锁屏拒绝（CoreDevice10002／FBSOpenApplicationErrorDomain7，`/tmp/camera-enhance-launch.log`），没有把启动失败或未执行的录制验收记为成功。最终格式与边界复检通过（`/tmp/camera-enhance-format.log`、`/tmp/camera-enhance-boundaries.log`）。

原生界面测试工具检测Mac锁屏，已请求解锁；模拟器不证明真机摄像头／麦克风行为。真机仍需独立确认：前后镜头照片、倒计时取消、支持设备的闪光灯与变焦、10秒有声录像／手动停止、两路预览与YOLO、最小化录制、后台封装、原聆听意图恢复、视频保存／回放／导出／忽略。性能与功耗未实测，不从动画或编码实现推断。

## 2026-11-01 通用标题栏布局

WindowChrome展开状态采用左右等宽88pt区域，左侧最小化／最大化（或还原），右侧加载占位／关闭；标题相对整个窗口居中。卡片左右各44pt，标题居中、关闭在右。按钮保留44pt命中区，标题单／双击和拖动仍独立。WindowState同步改为横向保留完整标题栏，防止移到右侧的关闭按钮被拖出安全区；纵向内容仍可部分移出。

窗口专项命令 `swift test --filter 'window|Window|cameraLens'` 退出0（`/tmp/window-chrome-targeted.log`），新增回归验证左右拖动、移动指令、结束拖动及安全区缩窄后两侧控制均可达；原有旋转断言由左侧240pt提升为完整窗口宽度。专项也覆盖窗口状态、镜头可见层、Gateway和生命周期用例；不把纯状态测试等同于原生触摸验收。

真机构建、严格签名及25项资源校验通过（`/tmp/window-chrome-device-build.log`）。2026110109已原位安装到iPhone17 Pro（安装流水5332），系统应用清单确认版本；安装日志`/tmp/window-chrome-install.log`。标题观感、按钮点按和拖动手感仍待真机验收。四iOS构建（MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero）全部通过，模拟器包25项资源校验通过，日志`/tmp/window-chrome-ios-build.log`。完整check.sh退出0：944项集成测试（64.890秒）、225项实时测试（206.174秒）及其余产品测试、Python／边界／严格Swift格式／plist检查通过，日志`/tmp/window-chrome-check.log`。最终git diff --check通过；构建和实时检查未并行。

## 2026-11-01 摄影收尾与背景透明度

build2026110108：仅Face背景CameraFrameView改为0.30不透明度；摄影Task的保存／忽略终结采用独立closeCamera请求，收到关闭成功后才finishTask。BasicSkill与Photography同时更新，取消／替换也先收尾，明确重拍保留窗口，失败不重放已提交处置。无Task的拍照保留照片查看，背景视觉不受摄影关闭影响。

快门声检查：Foundation未抑制AVCapturePhotoOutput原生快门声，AppleAudioIO允许录音期间系统声音；未新增合成声音或修改静音策略。用户此前截图带静音图标，但没有据此断言全部无声场景的原因。用户随后明确选择“跟随系统静音（使用原生快门声）”，因此保留该路径，不增加绕过静音的声音。参考SDK27 AVCapturePhotoOutput.h及[Apple系统声音录音开关](https://developer.apple.com/documentation/avfaudio/avaudiosession/setallowhapticsandsystemsoundsduringrecording(_:))。

提示词专项最终6项通过（`/tmp/camera-polish-targeted.log`），覆盖分请求示例解析、Action真实路径、失败保留／重拍／视觉独立提示和预算。此前新增规则超出提示预算，精简后默认24978、摄影31930字节，未提高25000／32000限额。首轮完整检查仅一个旧文本断言失败：精简时改写了“Skill IDs are loading arguments, not executable tags.”；已恢复原句并通过专项复验。该轮944项集成测试其余通过，225项LiveRuntimeTests全通过（205.798秒），记录 `/tmp/camera-polish-check.log`；最终完整复验单独记录，不把首轮写为全通过。

真机构建、严格签名与25项资源校验通过，日志`/tmp/camera-polish-device-build.log`。已原位安装到iPhone17 Pro（安装流水5324），设备应用清单确认0.1.0/build2026110108；安装日志`/tmp/camera-polish-install.log`。本轮没有代替用户发起新拍照或真实模型对话，快门听感、30%背景效果、语音摄影结束后关闭窗口仍需真机验收；安装成功不代表这些验收通过。

四iOS构建（MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero）全部通过，模拟器安装包25项资源校验通过，日志`/tmp/camera-polish-ios-build.log`。最终check.sh复验退出0：944项IntegrationTests全通过（64.162秒）、225项LiveRuntimeTests全通过（206.400秒），其余测试产品、6项Python测试、模块边界、严格Swift格式和plist检查全部通过。日志`/tmp/camera-polish-check-final.log`；构建与实时测试分开运行。最终git diff --check通过。

## 2026-11-01 前置拍照 photoFailed

用户在 build2026110105 报告前置镜头手动与语音拍照均失败；执行记录显示 open 成功，takePhoto 约0.41秒失败，两个问题条目均只有photoFailed。诊断版2026110106（安装sequence5308）保留原生错误，并只打印尺寸／字节数和错误域码。

真机控制台 `/tmp/front-photo-diagnostic-live.log`：原生处理返回4032×3024、5542949字节JPEG，processing和finished均为error=none/0；随后原来的4194304字节结果上限拒绝该成功照片。确认该次失败是输出字节预算，非权限、窗口或系统快门失败。没有读取、保存或提交用户照片到仓库。

修复保持返回4MiB及下游预算，超限原生JPEG通过已有Image I/O有界编码适配；不重拍、不改共享采集或Action入口。原生回执错误不再抹成统一photoFailed。小原片保持原字节，超限编码应用方向并保持构图；编码取消需加入，完成快门后不因取消编码停止共享预览。首轮原生编码定向8项测试通过（含4个图像尺寸参数），覆盖合成大JPEG、方向／比例、普通输入预算不扩大、小原片不变、非法预算／数据及取消。随后追加镜像构图回归，随完整检查执行。日志 /tmp/front-photo-encoding-tests.log。build2026110107真机构建、严格签名和25项资源校验通过，原位安装sequence5316；首次启动被系统preflight拒绝，重试明确报告iPhone锁屏，已请求解锁，未将安装写为拍照成功。四iOS构建（MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero）全部通过，模拟器包25项资源校验通过；日志 /tmp/front-photo-fix-ios-build.log。完整check.sh在无并行构建下运行，943项IntegrationTests通过（66.288秒），新增镜像用例通过，225项LiveRuntimeTests全部通过（206.176秒）；check.sh最终退出0，Python／边界／严格Swift格式及plist检查通过，日志 /tmp/front-photo-fix-check.log。用户解锁并用修复版复测后明确反馈“正常拍摄了”，记为用户完成的前置拍照实测；没有重启App或替用户处置当前照片。后置拍照、本轮具体语音句式及新照片的精确编码字节数未独立记录，不扩大验收范围。独立设备应用清单确认0.1.0/build2026110107。

## 2026-11-01 真机开启相机闪退回归

用户在 build 2026110103 实测开启相机闪退。读取 iPhone 17 Pro 的 `MobileHarness-2026-11-01-121553.ips`：SIGABRT / EXC_CRASH，异常栈落在 `AVCaptureVideoDataOutput.setVideoSettings` → `AppleCamera.configurePhotoGeometry` → `AppleCamera.start`。后续连接控制台重现同一崩溃，系统明确报告自定义输出尺寸未保持 source device activeFormat 的 aspect ratio。此失败推翻了仅凭之前构建／安装／启动就可判断开启相机可用的推断，之前记录的构建与自动化结果仍只证明各自范围。

修复使用原生 preview-sized buffers、不提交手动宽高，并检查实际几何和既有像素预算。动态比例设备读取 dynamicDimensions。同时修复 BasicSkill／ApplicationControl／Photography 的意图入口说明，并恢复 Face 右上角胶囊视觉开关／条件翻转／设置及左上角真实 YOLO 统计。

新增几何回归覆盖有效尺寸、错比例／转置／零负值／超预算和不兼容照片尺寸；Skill 回归检查 Vision 与 Capture 的独立绑定和 BasicSkill 无常驻相机 Action。首轮定向自动化5个测试通过（含10个参数化失败输入）；这是纯几何／目录／Gateway替身证据，不能代替真机开启、语音模型选路或真实照片验收。

build 2026110104 构建／签名／25项资源校验通过并原位安装（sequence 5292）。Device Hub 实际屏幕和控制台确认开启不再崩溃，但配置校验失败：原生 source=4032×3024，preview=1206×1608。改为接受系统输出方向导致的90度转置，照片源比例不变；这次失败保留，不把“无闪退”当作相机可用。build 2026110105 已完成修订、签名和25项资源校验，并原位安装（sequence 5300），诊断启动成功。真机屏幕确认视觉关闭时只有眼睛与设置；随后连接控制台记录原生预览1206×1608和1608×1206、已接纳CameraFrame及多次 DIRECT_CAMERA_GPU completed；本段记录无原有尺寸异常，证明设备实际出帧和GPU提交完成。照片捕获、视觉／跟踪语音选路、YOLO统计与窗口交互的完整用户验收仍待反馈。会话最后报告进程exit code 0，不据此推断用户关闭原因。

首次 check.sh 的普通阶段有2个失败用例：提示词用例仍断言旧的所有相机操作统一归 photography 文案（已改为两路分流断言）；slowTrackingDispatchExecutesOnlyTheNewestPendingTarget 的最终角度断言失败，保留断言与生产实现，安排在无并行构建时复查。该轮225项 LiveRuntimeTests 全部通过，不能将首次全量检查写为通过。build-ios.sh 的 MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个构建全部通过，模拟器包25项资源校验通过。无并行构建的最终 check.sh 普通阶段939项 IntegrationTests 已通过（61.802秒），先前两个失败用例和新增几何用例均通过；其余普通测试产品通过。串行225项 LiveRuntimeTests 全部通过（204.350秒），check.sh 最终退出码0；Python检查、边界检查、严格Swift格式及plist校验通过。最终日志为 /tmp/camera-regression-check-final.log；四构建日志为 /tmp/camera-regression-ios-build.log；真机105日志为 /tmp/camera-regression-live-105.log。原生界面操作工具能够读取 Device Hub 屏幕，但坐标点击返回 noWindowsAvailable，未把工具未执行的点击记为通过；实际出帧证据来自用户操作期间连接的真机日志。性能／功耗未测量，真实语音意图和完整照片处置仍待用户反馈。

日期：2026-11-01。范围见[已批准需求](../requirements/Face-Window-Island-Plan.md)。修改尚未提交。本轮双用途 Camera 修订已覆盖安装到 iPhone 17 Pro，版本0.1.0 / build 2026110103；安装与功能验收分别记录。

## 双用途 Camera 与可见层级镜头权限

本轮把照片窗口和 Face 视觉／YOLO／跟随拆成独立需求，复用一份 Camera 采集。最小化只隐藏照片窗口渲染，最后一个需求关闭才释放硬件。Foundation 发布 platform.vision.camera，UI 和 Action 按同一可见表面判断镜头权限。

自动化覆盖窗口打开／最小化／恢复回执、失败和迟到回执、遮挡与隐藏 Face、图像比例及边界、渲染器故障隔离、Perception 类型化输入到 Gateway／Action 的调用链、被动 Camera Facts 不创建或开启设备。新增 PerceptionActions.swift 遵循统一 CameraActions、显式 Module 和协议绑定，已加入 Xcode 文件引用。

首轮检查发现并修正了旧行为断言：全局渲染失败、ApplicationControl 原数量、Skill 教学术语、未知字段 null。保留这次失败记录；以下为修正后的结果。

最终自动化记录：

- `./scripts/check.sh` 退出0，边界／元数据、Python检查、严格格式、各 Swift 测试产品和 plist 校验通过；其中 IntegrationTests 935 项、LiveRuntimeTests 225 项通过。日志 `/tmp/camera-split-check-final.log`。
- 几何缓存修正后，CameraFramePresentation、CameraControlAvailability 和 WindowState 定向复测31项通过；包含四角适配／旋转／镜像，以及连续帧不触发 photoAspect 观察更新。日志 `/tmp/camera-geometry-final.log`。这些是几何计算与工作流测试，不是真机四边取景验收。
- `./scripts/build-ios.sh` 四个模拟器构建全部成功，日志 `/tmp/camera-split-build-verified.log`。包含最后比例缓存修改的主应用增量构建也成功，日志 `/tmp/camera-split-app-final.log`；最终 App 的25项 Skill资源及编译函数声明校验通过。
- 最终严格格式检查与 `git diff --check` 通过。没有新增目录或第三方库。

实施时环境限制：界面工具报告 Mac 锁屏，两台真机均 unavailable；用户选择先完成自动化验证。随后用户请求安装，iPhone 17 Pro 已连接并完成下述安装。本轮交互验收仍未完成，没有新的功耗、帧率或取景四边一致性测量。

### 双用途版本真机安装

按用户要求，复用现有本地签名，构建 MobileHarness / Debug iPhoneOS，命令行构建号2026110103。构建、严格深层签名校验和25项 Skill资源校验通过。devicectl 原位覆盖安装成功，databaseSequenceNumber 为5284；没有卸载或清空应用数据。独立应用清单确认 dev.mobileharness.app 版本0.1.0 / build 2026110103，系统启动请求成功。安装与启动不代表双路采集、镜头控制或实际取景验收通过。

本机证据：`/tmp/camera-split-device-build.log`、`/tmp/camera-split-device-install.json`、`/tmp/camera-split-device-installed.json`、`/tmp/camera-split-device-launch.json`。

待真机验证：

- 仅视觉、仅拍照、两路并开；增减一路时另一画面与跟随不中断，关闭最后一路后隐私指示灯熄灭。
- 展开时背景翻转禁用；最小化后背景可翻转，恢复后两路显示同一实际镜头；过渡和忙碌时明确拒绝。
- 前后镜头各拍摄四边标记，核对预览与成片视野、比例、镜像、旋转，覆盖最大化和横屏 iPad。
- 模型或单个渲染器失败不破坏另一画面；前后台不自动重启；保存、忽略、取消和关闭仍可完成。

## 此前窗口版本的验收证据

## 自动化

新增 WindowStateTests、WindowExecutionTests、WindowGatewayTests 分别覆盖：

- 安全区默认布局、拖动约束、普通/卡片位置独立、最大化还原、颜色与实例稳定、四窗口容量及焦点。
- 显式模拟呈现回执，验证替换取消、过期 revision/generation、后台解除等待、关闭决策与取消。
- 领域暂停失败保留窗口、呈现完成后恢复、关闭清理失败保留实例、关闭只打断同实例操作。
- 类型化 UI 请求经 ApplicationControl/Gateway/Window Action，以及两个 Skill 别名一致、BasicSkill 不扩展。

上述测试使用测试内容/生命周期替身和明确模拟回执；产品无演示窗口。不能用它们证明 UIKit 动画或真实摄像头停机。

完整检查首轮发现 Photography 提示词预算及新增 State/Capability 测试清单未同步，已修正。窗口端到端测试识别并修正 ApplicationControl 未认领窗口 Tool 回执的问题。

最终单独执行 `./scripts/check.sh` 返回0：模块边界、Python检查、Swift格式检查、全部默认测试和配置检查通过。其中 IntegrationTests 为933项，串行 LiveRuntimeTests 为225项；新增窗口测试9项分布于UI、workflow和集成目标。Photography 合并提示词31,249字节（限制32,000），BasicSkill未扩展。真实模型评估未运行。

并行构建期间，已有 `residentNativeStatePreservesFailuresAndRecoversOnObservation` 出现一次 invalidSnapshot/等待超时；隔离复测通过，最终完整检查也通过，未修改其生产逻辑或断言。

`./scripts/build-ios.sh` 的 MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个iOS Simulator构建通过；最终窗口安全区、圆角透明命中、加载外观和相机关闭忙碌边界的App增量构建通过，最后修改的UIKit/相机文件也通过严格格式检查。最终包内资源检查识别25项资源。`git diff --check`通过。

## 模拟器交互验收

2026-11-01：用户解锁 Mac 后，通过 Xcode Device Hub 实际操作 iPhone 18 Pro / iOS 27.0 与 iPad Pro 11-inch (M5) / iPadOS 27.0。使用产品入口和真实 WindowHost，无演示窗口或业务替身。

未签名的构建校验包初次启动发生配置/钥匙串读取失败。用同一源码经 Xcode `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 构建并覆盖安装后，正常进入 Face；没有修改仓库签名配置或读取用户密钥。

| 场景 | 实际观察 |
| --- | --- |
| 默认窗口与相机失败 | 窗口居中、宽度保留边距、高度约安全区2/3；模拟器无摄像头时保留失败窗口与重新开启入口。未做像素级尺寸测量。 |
| 普通拖动与边界 | 标题拖动跟随位置；可部分出右边界，三控制按钮仍可见；向左上拖动被限制在安全区。未测量回弹曲线。 |
| 最大化/还原 | 按钮和双击标题切换成功；还原保留拖动后的普通位置。最大化后最小化，再单击卡片恢复到最大化。 |
| 最小化卡片 | 显示标题/关闭按钮，拍摄内容从可访问树消失；拖动不误触恢复；同一实例保持底色；iPad 左上边界约束后卡片完全可见。 |
| 触摸透传与页面 | 窗口外点击 Face 设置按钮正常进入设置，窗口仍覆盖设置页；关闭窗口保留设置页。长按聆听未验收，模型未安装。 |
| 单实例与关闭 | 连续点击 Face 相机入口仍仅一组窗口控件；展开窗口及卡片关闭均移除窗口，无待处置照片。 |
| 横竖屏 | iPad 普通窗口随横屏重新布局；横屏最小化再旋回竖屏，卡片仍在安全区内，控制按钮可达。iPhone 产品配置为竖屏。 |
| 权限拒绝 | iPad 首次授权弹窗引起场景失活并撤销当前请求，保留窗口；拒绝后重试显示明确权限失败和系统设置入口。未开启权限或拍摄。 |

实测发现并修正：Face 相机入口不再受对话模型准备失败阻塞；权限弹窗导致的 UIRequestError 改为可理解的重试提示，不显示内部类型/数字错误码。相机入口修正已通过上述模拟器交互验证，最终提示文案通过工作流回归验证；首次授权弹窗的最终文案尚未重新清空权限复测。

签名后的资源包包含 Apple `_CodeSignature` 元数据，原资源脚本误报 stale；现只排除四种已识别标准签名文件，25项业务资源仍逐字节核对。实测正常签名包通过，并插入临时未知资源验证明确拒绝，随后移除该测试文件。

交互期间设备管理器曾出现 AX 超时；同时运行两个模拟器时发生，关闭第二个模拟器后恢复可操作。本轮不由此推断应用帧率、耗电或内存表现。

入口修正后完整 `./scripts/check.sh` 返回0，LiveRuntimeTests 225项通过（216.985秒）。其后请求提示修正的定向回归3个测试通过，包含 stale/unavailable/consumerEnded 三种参数、取消后重试及保存成功事实保留；严格 Swift 格式检查通过。真实模型评估仍未执行。

最终再次执行 `./scripts/build-ios.sh` 返回0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个构建均成功；App 资源校验25项通过。最终模块边界复查及 `git diff --check` 通过。模拟器安装包用于上述界面验收，构建检查包不等同于已签名真机安装包。

## 真机独立验收

尚未执行：窗口拖动/回弹、按钮与内容点击、最小化/恢复动画、Face 触摸透传、Camera 采集/租约释放与恢复、权限拒绝后重试、保存/忽略/取消关闭、前后台、旋转、Reduce Motion/Reduce Transparency/VoiceOver。没有帧率、功耗或内存实测结论。

## 真机安装（2026-11-01）

按用户要求，以当前工作区构建 MobileHarness / Debug iPhoneOS，复用现有本地签名，命令行构建号 `2026110102`。构建成功，严格深层签名校验及25项 Agent/Skill 资源校验通过。

原位覆盖安装到 Youwei’s iPhone 17 Pro（`dev.mobileharness.app`），devicectl 安装成功，databaseSequenceNumber 为5276；未卸载或清空应用数据。独立应用清单确认版本0.1.0 / build 2026110102，系统启动请求成功。此证据只代表构建、安装与系统启动，不代表上述真机功能验收完成。

本机临时证据：`/tmp/mobileharness-window-device-build.log`、`/tmp/mobileharness-window-device-install.json`、`/tmp/mobileharness-window-device-installed.json`、`/tmp/mobileharness-window-device-launch.json`。
