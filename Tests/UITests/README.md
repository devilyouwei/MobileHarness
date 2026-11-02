# UI State and Interaction Tests

✅ 覆盖请求等待与模型加载独立、请求身份替换、停止与失活清理，不以状态测试替代原生动画验收。

✅ 更新准备展示回归，真实加载不提供文字／取消／重试，仅失败提供重试；检查与就绪无等待 UI，大小眼原生动画及退出另做真机验收。

## 职责与边界

WindowStateTests 验证窗口在向左右拖动、Action位置更新及安全区缩窄后的完整标题栏可达性，并保留普通／最大化／卡片位置独立性。标题视觉居中、按钮点击与标题拖动隔离仍需iOS原生界面验收。

根 Package.swift 的 UITests target 只依赖 UI，测试 UI-owned 状态和值，不引用 App、Agent、数据库、模型或设备实现。以 Swift 状态测试为主；常驻导航使用原生 macOS 挂载回归，iOS 触摸/渲染验收另行进行。

✅ PersistentHomeNavigationTests 在 macOS 原生 SwiftUI/AppKit 窗口中挂载与生产相同的常驻导航容器，验证多层 push/pop、覆盖时首页原生视图身份/窗口挂载、持续状态更新与 page task 不取消，以及根销毁时清理。该回归不替代 iPhone 的 Core Animation、语音和物理动作验收。

## 当前用例

| 文件 | 契约 |
| --- | --- |
| SettingsStateTests | 草稿与已确认值、独立语音模式、操作准入、错误/显式重试与保留未提交编辑 |
| BluetoothConnectionStateTests | 连接/打开详情/不可用意图、已连接与记忆分组、失效回调、断连操作约束 |
| AudioDetectionStateTests | PCM freshness 与方向独立过期、quiet/unavailable、可执行角度清理 |
| ConversationHistoryPresentationTests | 请求行/任务索引、分页游标与重试、原始 JSON/图像引用、时间/缺失值、初次加载 gate 和返回详情保留页状态；native-only/mixed Tool Call 展示、实际结果/失败保留与未测计时不补造 |
| ExecutionLogTests | 完整子错误、Channel/task 分组、终态/取消与展示值 |
| EyeGeometryTests / ListeningMotionTests | 几何、眼睛/聆听运动、epoch 和有限状态 |
| PhotoDepartureTests | 照片退出状态、身份 fence 与完成条件 |

测试操作使用注入结果及明确完成信号；执行结果到 UI 值的映射属于 AppWorkflowTests。历史页的返回保留检查验证 gate/缓存状态，不声称已验证 native List 的真实滚动位置。

CaptionPresentationTests 覆盖部分文本→最终修订、定稿与移动不丢字符、连续替换、320 Character 上限、emoji/组合字符的 UTF-16 范围及 Reduce Motion。不以值测试代替原生TextRenderer/动画帧率验收。

## 待实现

- 原生 List 分页/下拉刷新/返回手势和滚动位置保持。
- 真实图片/长历史/错误展示、布局、动画与辅助功能验收。

运行结果与设备证据记录到 [validation](../../docs/validation/README.md)。

✅ 历史 token 展示覆盖缓存读取/写入、零值、缺失与旧 JSON 兼容；不从总输入反推缓存命中或费用。


## 分类异常诊断

✅ 验证诊断详情的有界保留及短 userMessage 展示，不将错误详情直接塞入 toast。

## Platform 根、设备接入与同帧呈现

✅ CameraFramePresentationTests 验证图像独立提交、姿态失败不清图、姿态独立过期、重复/错帧拒绝和渲染故障的代际围栏。测试使用合成像素，不代表 Metal 上屏或真实摄像头验收；证据见 [专项验证](../../docs/validation/PlatformKit-Containers.md)。

✅ CameraFramePresentationTests 另覆盖相机渲染最新槽的合并、排空后的再接纳、停止拒绝，以及骨架网格的缓存、容量、镜像和方向约束；不以状态/几何测试替代原生显示链与 GPU 线程的设备验收。

✅ macOS 上直接运行生产 CameraMetalRenderer，合成 Metal 兼容像素并验证真实 display-link/GPU 完成、无帧停止及反复启停/同图层接管。测试不使用真实相机或 YOLO，不代表 iPhone 上屏性能验收。

✅ 相机到期回归按可观察状态作有界等待，替代固定 90 ms 睡眠，允许原生窗口与主线程调度在不同机器上有合理抖动；仍断言姿态过期时新鲜影像保留。

## UI 容器与相机能力注入

✅ 新增 UI 根/相机容器隔离、生命周期围栏、清屏、到期任务加入与停止后拒绝媒体回归，并保留相机独立输出和原生 Metal 回归。

## UI 全量容器化

✅ 应用级 UI 状态由八个子容器统一创建，消费者注入所需 Presenting 接口并提交 UI 自有值，不直接写字段。App 注册并管理同一 UI 根；原业务身份/版本校验、原生完成和基础库依赖边界保持。跨模块连接迁移仍是独立待办。

✅ EyeGeometryTests 覆盖频谱原生路径的固定拓扑、32 段上限、非有限输入清理、失活和 Reduce Motion 的数值隔离；真实图层插值与帧率仍须真机验证。


✅ UI 回归直接覆盖根、字幕、表情、几何、历史分页及 Metal；渲染测试以实际 GPU 完成计数判断，不以状态接纳代替真实完成。

✅ 已补充连续帧延后到期、更早捕获期限、清屏后重新接纳及重复停止／释放回归；光环重复停止、无帧退出与所有者释放测试仅在 iOS 编译／执行，不将 macOS 状态测试视为该原生测试通过。带在途 GPU 帧的光环退出及真机功耗仍待验收。

✅ 覆盖历史消息读取取消／迟到／重复点击与替换前加入、异步目录取消与时间线结果等价；光环失败只报告一次及重复状态不唤醒使用生产接纳逻辑验证，不代替原生GPU故障注入与功耗验收。

✅ 覆盖TextRenderer字幕的连续追加进度、中文／emoji修订、滚动320字符窗口、清空与定稿／Reduce Motion／失活；原生离屏渲染验证新增run透明度与最终可读性，不以离屏测试代替真机流畅度。

✅ 已实现：覆盖准备状态与业务语音状态独立、同根接纳、失活／stop迟到拒绝及已有停止入口资格。

✅ 已实现：蓝牙呈现状态生命周期／revision隔离和连接中状态的纯值验证；原生图标位置／动画另需真机验收。


✅ UI根停止后start／setForeground断言UIFailure；相机领域呈现的过期／代际错误保持原协议，避免将逐帧拒绝误作根故障。



✅ 覆盖加载表情在未聆听时显示、终态清理、同revision冲突／旧revision拒绝、前后台及旧根拒绝；眼睛拓扑测试包含loading形状。

✅ 已实现：覆盖 checking 拒绝加载表情、加载后复查清除表情及真实 preparing 仍能加载。

✅ 已实现：加载投影的旧版本、准备结束、后台及会话接管返回 superseded，版本水位阻止旧动画复活；冲突／停止拒绝不吞掉。

✅ 已实现：所有模型准备状态均不显示准备文字；真实 loading 只显示等待眼睛，失败才有重试按钮。

❌ 待验证：返回转场显示常驻首页。现有 macOS 原生挂载回归确认状态／实例／任务保留，iOS 导航容器透明及交互返回完成／取消需要原生真机另验，不用挂载断言代替可见性验收。

✅ 请求等待属于可被有限表情演出覆盖的装饰，不使真实表情动作报 busy；模型实际加载仍保留原有独占契约。



## 类型化输入回执

✅ UIRequestsTests 覆盖无消费者、重复消费者、普通未终态 64 上限、接纳与完成分离、取消、关闭、根代际及迟到结果。独立单槽控制请求可以在普通请求未完成时执行，控制满载明确拒绝。业务授权与真实设备执行由 IntegrationTests 覆盖。

## Agent-owned UI inputs

✅ Home listening has its own control-only single-slot source; root availability/stop governs it alongside ordinary home requests. Existing receipt tests retain unavailable/duplicate/capacity/cancellation/generation coverage. Actual owning-Agent subscription and execution regressions belong to IntegrationTests.

✅ 订阅关闭携带消费者 token，旧订阅退出不能关闭恢复后的消费者；恢复前加入旧消费任务。暂停期间仅允许经身份校验的本地取消／retire 清理，不接纳新的业务请求。

## 直连链路收尾

✅ 类型化入口与 Metal 真实绘制／停止／交接保留实际断言；窗口不可见仍失败，不以跳过或替身绘制完成验收。执行结果记录于 docs/validation。

## Runtime validation isolation

✅ CameraFramePresentationTests 的五个实际期限用例与三个相机根／媒体生命周期用例归入现有 NativePresentationTests 串行阶段，涵盖视频／骨架过期、续期、提前期限替换、旧会话清理和停止加入。iOS 原生 halo 停止用例也归此阶段。只改变测试调度，原断言、500 毫秒等待上限和 750 毫秒生产期限保持；默认检查执行 macOS 普通 UI 107 项、串行 UI 10 项。锁屏期间的无窗口验证显式排除两个可见窗口用例，不代替完整检查。

The default check runs ordinary tests concurrently, then executes the live-runtime and native-window suites separately. These suites are serialized because their assertions use real capture freshness, mechanical deadlines, media expiry, or the process-wide AppKit application. Business concurrency remains exercised inside each test. No global parallelism flag or production deadline is changed; excluded cases in the first phase must execute in the second.

Native window cleanup is registered immediately after creation, including failed visibility prerequisites. The command-line host dispatches available AppKit events between asynchronous yields while awaiting visibility and actual GPU completion. It does not enter a nested blocking application loop. A failed visibility prerequisite remains a failure, and production renderer behavior is unchanged.

Provider 状态回归覆盖多配置恢复和 revision 围栏，敏感草稿在根停止时清空。

Provider 名称持久化、默认名称生成、独立弹窗草稿、重复 URL 和空名称校验由自动化回归覆盖；原生弹窗布局与粘贴需设备验收。

✅ providerModalAcceptsHTTPAndHTTPSIPAddresses 覆盖 HTTP/HTTPS IPv4、IPv6、端口与路径，仍拒绝 FTP；不访问真实网络。

Implemented: Provider URL input is optional. Blank/whitespace input resolves to https://api.openai.com/v1 on modal confirmation, sharing the same URL identity as an explicit official endpoint. Keep name/key, duplicate checks, and nonempty HTTP/HTTPS validation. Cover default resolution and duplicate default providers.

✅ 镜头切换回归覆盖全局准备checking／preparing／deferred／failed时已就绪相机仍可切换，并验证拍照／相机操作、未启用／未就绪、权限与前后台准入。

前后台回归遵循原有清屏契约：返回前台本身不代表采集已恢复；收到新的相机就绪确认后才允许翻转。

## Container 上下文

✅ NavigationContextTests覆盖手动路径回写、路径提交与确认分离、详情／覆盖层、迟到代际和父页更新拒绝，以及离开相册后的操作事实隔离。视图挂载和真实手势仍需原生验收。

Camera orientation regression uses asymmetric synthetic sensor geometry across all capture/interface quarter-turns and mirror cases. It verifies portrait-lock crop stability, image/pose and gaze axes, nil-reference compatibility, orientation-only mailbox/mesh invalidation, stale sensor-reference rejection and no per-video invalidation of gaze presentation. These checks do not substitute for physical iPhone rotation or native camera acceptance.

WindowStateTests uses explicit synthetic presentation acknowledgments to verify geometry, capacity, focus, identity/color stability, independent positions, cancellation and stale-generation rejection. These are state-contract tests, not native animation or device acceptance.

Window regression covers image-aspect sizing, visible camera lens authority, minimized/restore handoff, occlusion, hidden Face and failed/stale presentation receipts. Renderer-failure tests prove shared frames remain available to the other surface.

Photo geometry tests retain all four image corners under fit, rotation and mirroring. Observation tests ensure unchanged frame dimensions do not invalidate the root-facing photoAspect value. They do not replace physical lens field-of-view measurements.

Shutter-orientation regression checks both native portrait sensor references across all window/gravity quarter-turn combinations, frozen snapshots, Face/window independence and missing-frame rejection. It validates geometry values, not native JPEG metadata or a physical shutter.










系统灵动岛验证覆盖活动容量/owner/revision/generation、原生提交合并/迟到状态/权限失败、阶段提醒去重与上限、后台暂停与根清理、导航白名单；Actions/Skill验证expanded请求与旧自定义几何拒绝、Task身份/中文状态/终态移除。自动化不证明系统动画或真机视觉效果。

灵动岛双呈现回归覆盖通用详情阶段/收起/结束、普通状态拒绝展开、相机优先整活动切换、后台只保留当前活动摘要、真实渲染回执围栏、频谱不重发摘要及系统失败下前台独立。布局检查左右同边距、硬件保护和有界标准圆角矩形；不替代真机动画验收。

IslandStateTests还覆盖收紧边距后的硬件避让/展开布局，以及上滑收起的方向和位移边界；真实UIKit命中、动画及系统状态栏覆盖需真机验证。

Island内容回归覆盖无阶段详情自动展开、逐活动收起记忆、整活动抢占/恢复、无详情拒绝展开、旧字段单向迁移、指标编码、真实ImageIO缩略图缩放、归属/绑定/容量/取消与清理。系统快照仅包含当前活动，图片不进入原生摘要。

紧凑岛几何回归覆盖受测402pt设备的14pt顶坐标/36.67pt固定高度、左右槽零内间距、外侧5pt留白、单侧无空翼、硬件中心不随内容移动及展开还原复用同一紧凑frame。

收起重开回归覆盖中央黑区、左右槽命中与内容保留、圆角外透传，以及竖屏相机初始位置避开普通展开岛、保持取景比例和底部安全区；不等同于UIKit真机触控验收。

Island后台连续性测试验证同代活动仍可更新系统摘要、无paused副本，手动收起偏好和身份在返回前台后保留，根停止结束原生活动；使用系统驱动替身，不代表锁屏音频真机验收。

聆听计时覆盖elapsed编码/非法日期、固定高度与硬件对齐，以及连续聆听跨后台/领域更新保持起点、重新聆听重计。

系统状态条回归覆盖向外挤压后才隐藏网络/电池、各种视口不遮业务或越界、真实本地挂载和前后台/失活标志、未知电量及失败清空/报告去重；状态栏系统合成由真机验收。

系统状态与业务同壳回归验证所有可见元素被实际岛身容纳、统一左右内边距与垂直中线、展开/紧凑坐标转换不漂移，以及电池轮廓固定、填充随电量变化、端帽独立和未知空填充。

灵动岛展开几何验证顶部业务与系统状态共同下移、硬件区固定、详情间距与底部留白，并保持完整业务双翼的系统状态避让。

Island几何回归覆盖紧凑黑色背景只包含业务、全宽系统状态坐标不变、展开背景包含完整容器，以及紧凑透明系统状态区域不接纳展开点击。

Island兼容解码测试覆盖旧destination/linkTitle被忽略、重新编码不再携带导航字段，系统快照仍固定唤回App。业务状态与任务详情的身份、图片及代际验证由既有用例保持。
