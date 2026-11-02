# Window / Camera 验证

## 2026-11-02 紧凑岛外侧留白（148）

- 外侧padding从5pt调到8pt，每边增加3pt；几何与视图共用原常量，不改变高度、符号、中央保护区、展开正文和系统Widget边距。既有尺寸断言同步更新。
- 完整check执行结束（`/tmp/island148-check.log`），退出1：第一次测试编译先于两条总宽度断言更新，仍使用179.333333pt及27pt旧值而失败。最终全部176项UI复验通过（`/tmp/island148-ui-summary.log`，退出0）；首轮967项集成、138项Workflow、225项LiveRuntime（205.954秒）、格式/边界/plist通过。原生Metal用例只有started无完成摘要，不计通过；没有把首轮check退出1描述为通过。
- 四项iOS构建及资源校验通过（`/tmp/island148-ios.log`），git diff --check通过。未安装真机、未commit；实际边距观感待用户确认。

- 后续按用户要求安装：Debug真机版本2026110220构建成功（`/tmp/island148-device.log`），Agent/Widget资源及codesign严格校验退出0（`/tmp/island148-agent-resources.log`、`/tmp/island148-island-resources.log`、`/tmp/island148-signature.log`）。安装成功，databaseSequenceNumber5628（`/tmp/island148-install.log`），包含147背景及148留白调整。启动因锁屏被拒绝，CoreDeviceError10002/Locked（`/tmp/island148-launch.log`）；解锁后可手动打开，不代表真机视觉验收通过。

## 2026-11-02 首页深蓝渐变背景（147）

- 核对仓库外Island145Preview.swift，采用相同RGB(0.08, 0.20, 0.32)至黑色纵向渐变。Root统一为首页/启动页提供底色，删除Conversation旧Atmosphere与Camera背景黑色；旧对比渐变移到视频内部再以30%合成，保留视频淡化和交互。窗口/灵动岛背景与Action接口未改，无新目录或资源。
- 完整check退出0（`/tmp/background147-check.log`）：176项UI、967项集成、138项Workflow、225项LiveRuntime（206.158秒）及格式、边界、plist检查通过。既有原生Metal测试只有started无完成摘要，不计为通过。此静态外观修改未添加重复实现的测试。
- 四项iOS构建、Agent及Widget包内资源校验通过（`/tmp/background147-ios.log`），git diff --check通过。未安装真机或声称真实界面验收通过，未commit。

## 2026-11-02 灵动岛封装与结构审查（146）

- 保留UI/Components/Island七文件与Actions/UI/Runtime两文件归属，不新增目录。UI独占内容/资源/仲裁/宿主/系统呈现，Actions只解释已有业务事实和执行通用呈现命令；Root仅组合组件与只读占用边界。未引入上层依赖、设备采样或业务动画参数。
- 删除destination/linkTitle公共内容、快照存储/校验/编码与领域赋值，移除仅补相机导航字段的包装方法；旧JSON额外字段可读取但不参与身份、也不重新编码。删除从未抛出的systemUnavailable、无效绑定、重复导入和不使用的旧编码键。控制/领域发布/图片接口集中IslandActions，DomainPresentation只保留观察转换。
- 归并Island README中累积重复段落，修正后台保留资源与根失活清理的界限，补齐Actions Runtime文件清单。ApplicationControl revision19、Photography revision33同步详情/实时状态独立选择，不改变Action路径、策略或常驻目录。
- 最终完整`./scripts/check.sh`退出0（`/tmp/island146-check-final.log`）：176项UI、967项集成、138项Workflow、225项LiveRuntime（204.240秒）及其他检查通过；原生Metal仍只有started无完成摘要，不计其通过。最终Skill修订号更新后补跑Island/Prompt/Skill过滤验证，45项UI、107项集成等通过（`/tmp/island146-focused.log`）；可选模型评估被测试配置跳过，不计真实模型验收。
- 首次四项构建在ModelKitRuntime包解析阶段超过6分钟无进展，SIGINT未退出后终止该自有进程并重启；最终四项构建通过（`/tmp/island146-ios-final.log`）。资源校验两次分别发现打包后更新的Skills README和Photography修订号未同步；最终重新打包通过（`/tmp/island146-resource-final.log`），Agent与Widget资源校验退出0（`/tmp/island146-resources-final.log`）。
- README相对链接与`git diff --check`通过。此次无视觉变更、不新增模拟器演示、不安装真机；此前145样式验收继续独立保留。既有Widget PreviewProvider在iOS27有弃用警告，仍用于四种系统呈现预览，不属于死代码；本轮未重写预览工具。

- 后续用户明确要求安装：真机Debug签名构建2026110219成功（`/tmp/island146-device.log`），Agent资源、Widget资源及codesign严格验证均退出0（`/tmp/island146-agent-resources.log`、`/tmp/island146-island-resources.log`、`/tmp/island146-signature.log`）。安装到连接的iPhone成功，databaseSequenceNumber5620（`/tmp/island146-install.log`）；自动启动被锁屏拒绝，CoreDeviceError10002/Locked（`/tmp/island146-launch.log`）。包含145动效及146清理；解锁后可手动打开，不代表真机视觉验收通过。未修改业务代码或commit。

## 2026-11-02 紧凑背景回弹与展开动效（145）

- IslandHost新增独立backdrop，容器仍承载完整状态行；紧凑背景只覆盖中央业务，展开覆盖全宽与详情。打开先全宽300ms再背景收窄520ms，展开/收起620ms；第二段真实完成后回执，替换/关闭捕获当前背景frame/corner，Reduce Motion直接目标背景+短淡入。透明系统状态区域命中透传，Action接口未改变。
- 完整`./scripts/check.sh`退出0（`/tmp/island145-check.log`）：175项UI、967项集成、138项Workflow、225项LiveRuntime通过；既有原生Metal用例只有started无完成摘要，不计通过。`./scripts/build-ios.sh`四项及模拟器包资源检查通过（`/tmp/island145-ios.log`）；`git diff --check`通过。
- Mac Device Hub/iPhone18 Pro运行仓库外`/tmp/Island145Preview.swift`，链接当前真实UI组件。实际验证首次聆听开场、任务展开、说话频谱、收起、点击紧凑业务区重开、连续6次80ms展开/收起打断后settled。网络/电池/频谱为明确标注的测试值，不调用设备相机/麦克风/模型。
- 通过Device Hub录屏并逐帧观察，确认开场黑色背景从全宽回缩至业务、系统状态保留；展开外壳连续扩展，顶部实时状态与下部目标详情独立。原始录屏在Mac桌面`Screen Recording iPhone 18 Pro 11-02-2026 at 5.04.29 PM.mp4`（文件名时间前为空格窄字符）；节选`/tmp/island145-review.mp4`，逐帧图`/tmp/island145-opening-detail.png`及`/tmp/island145-expand-frames.png`。录屏是模拟器视觉证据，不代表真机性能/功耗。
- 按本轮要求保留模拟器验收页，未安装真机；等待用户确认视觉与动效后再安装。Apple公开文档将系统外壳动画交给iOS，App内参数为本组件调校，不声称复刻系统私有曲线：https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities 。

## 2026-11-02 最大化窗口贴屏与灵动岛避让（144）

- WindowHost全屏挂载，最大化顶部使用Island本地占用底边+4pt，左右/底部贴视口；内部按钮保留安全内边距。Root仅传入通用topBoundary，Window不依赖Island。最大化去除壳圆角/边线，普通/卡片位置独立保存。
- 首次检查发现几何初始化误插入赋值，已删除；随后新测试CGFloat/Double混合比较失败，改为显式Double比较；Root大型表达式编译超时，抽取windowOverlay并显式转换坐标。最终完整`./scripts/check.sh`退出0（`/tmp/window144-check-accepted.log`）：174项UI、967项集成、138项Workflow、225项LiveRuntime通过。既有原生Metal测试只有started无完成摘要，本轮不计其通过。
- `./scripts/build-ios.sh`四项构建通过（`/tmp/window144-ios-accepted.log`）；真机构建2026110218通过（`/tmp/window144-device.log`），Agent资源、Widget资源及深度签名通过（`/tmp/window144-{agent-resources,island-resources,signature}.log`）。
- Mac Device Hub/iPhone18 Pro模拟器运行仓库外`/tmp/Window144Preview.swift`，链接真实UI组件；测试内容和网络/电池为替身，不调用相机/麦克风。实际点击最大化、收起灵动岛、还原，确认窗口左右/底部无露底、顶部小间隙随岛更新、普通窗口恢复圆角及原布局。横屏几何、最小化再恢复、占用清理由自动化覆盖，未称真机相机验收。
- 2026110218已安装到连接的iPhone（流水5612，`/tmp/window144-install.log`）；真实相机窗口贴边、拍摄控制可达与手势区仍由用户在设备上确认。

## 2026-11-02 Live Activity返回路由与进程退出边界（143）

- Widget所有整体点击改为mobileharness://island；UI根删除pending目的地和history/camera/bluetooth路由，旧活动路径不再触发页面跳转/相机启动。保留现有Scene导航和窗口，冷启动使用正常首页。
- App原生终止回调调用UI的IslandProcessLifecycle：在独立任务执行Activity.end(.immediate)，回调最多同步等待1秒，超时记录OSLog。UI驱动安装立即清理上次进程活动；系统过期/暂停/结束快照移除运行指标和计时，清楚标明状态失效。
- 首次iOS构建因DynamicIsland闭包增加局部快照后缺显式return失败；修正后四项构建通过（`/tmp/island143-ios-final.log`）。真机构建2026110217通过（`/tmp/island143-device.log`），25项Agent资源/Widget身份版本/深度签名通过（`/tmp/island143-{agent-resources,island-resources,signature}.log`）。
- 首次完整检查新增清理测试未先启用UI，flush按原契约抛interrupted（`/tmp/island143-check.log`）；修正测试启动顺序后复跑完整检查通过，结果见下。没有放宽生产代际/可用性检查。
- 最终完整`./scripts/check.sh`退出0（`/tmp/island143-check-final.log`）：171项UI、967项集成、138项Workflow、225项LiveRuntime（206.247秒）及其余检查通过；本轮原生`cameraNativeMetalDrawStopAndLayerHandoff`有明确passed（0.830秒），不再沿用之前缺少完成摘要的结果。最终`git diff --check`通过。
- 2026110217已原位安装（流水5604，`/tmp/island143-install.log`）并成功启动（`/tmp/island143-launch.log`）。Device Hub尝试连接真机屏幕，系统提示麦克风或相机活跃时不允许共享，未操作业务来强制关闭资源；因此未宣称真实后台点击/划掉验收通过。
- 平台依据：Apple applicationWillTerminate文档不保证挂起终止回调；Apple DTS明确回调返回后直接exit，不能只启动主actorTask后立即返回；staleDate仅表示过期，不执行end。参考https://developer.apple.com/forums/thread/824825 和 https://developer.apple.com/documentation/activitykit/activitycontent/staledate 。
- 未完成的真实验收：带后台音频/挂起两类状态下实际划掉、从系统岛返回设置/首页并保留窗口、过期后的原生Widget外观。没有APNs结束服务，本地实现无法保证所有强杀后立即移除；本轮只补齐有回调时的尽力清理、过期显示和下次启动清理，不能将第一项需求标为完全解决。正常后台持续对话不因这轮修改提前结束。


## 2026-11-02 任务详情与实时状态独立呈现（142）

- IslandState按有效详情/无详情状态分别排序；Host顶部选实时状态、下方选详情活动。任务的手动展开偏好不随相机/语音切换改变。Widget共享复合快照，详情作为身份锚点，独立detailPrimary/detailTone与hasStatus；旧快照仍可解码。Action参数未变，更新跨层设计说明。
- 完整`./scripts/check.sh`退出0（`/tmp/island142-check.log`）：168项UI、967项集成、138项Workflow、225项LiveRuntime（205.321秒），其余包检查/边界/严格格式/Python/plist通过。既有`cameraNativeMetalDrawStopAndLayerHandoff`只有started、无完成摘要，仍不计原生Metal验收通过。
- 完整检查后加强既有领域集成用例，验证真实IslandDomainPresentation的任务+聆听/说话/processing+相机倒计时；修改后的单项针对复跑通过（`/tmp/island142-integration.log`）。最终严格格式及`git diff --check`通过。
- `./scripts/build-ios.sh`四项构建及模拟器资源校验通过（`/tmp/island142-ios.log`）。真机构建2026110216通过（`/tmp/island142-device.log`），25项Agent资源、Widget身份/版本/入口与深度签名通过（`/tmp/island142-{agent-resources,island-resources,signature}.log`）。已安装，流水5596（`/tmp/island142-install.log`）；首次启动遇到CoreDevice远程XPC连接错误，重试后成功启动（`/tmp/island142-launch-retry.log`）。
- Mac Device Hub/iPhone18 Pro模拟器加载仓库外`/tmp/Island142Preview.swift`，链接真实UI组件，任务与实时状态使用独立slot。实际观察任务+麦克风计时、任务+扬声器频谱、任务+拍摄/加载，以及录像时保留详情；点击收起后切换loading保持收起，再点击状态恢复原任务；结束任务保留实时状态，重新提交任务后结束状态只移除上部指标。频谱/网络/电池为标注的注入数据，不是实际声音/设备业务验收；截图`/tmp/island142-task-speaking.png`。
- 未独立验收本轮系统Widget实际展开外观、真实语音/相机闭环、Reduce Motion/VoiceOver和功耗；不可用编译或合成场景替代。此次未复测中央硬件区域每一点的触摸，保留141的该项限制。


## 2026-11-01 真实 Face 顶部与详情展开修正（123）

122用户真机截图暴露独立胶囊与Face工具栏重叠，推翻上一轮组件夹具足以验证整页布局的判断。此次参考1998code/iOS16-Live-Activities的WidgetDemo.swift、ActivityAttributes.swift和ContentView.swift实际代码：系统紧凑/最小/展开/锁屏分别布局，expanded leading/trailing放状态与计时、center详情/进度、bottom返回App链接；App内保持同一轮廓定向伸展与向下展开。没有复制业务资源或保活代码。

- 初轮定向几何断言出现CGFloat与推断整数混用的同值失败，改为明确浮点期望；完整check.sh随后通过（/tmp/island-face-check.log）：156项UI、959项集成、137项Workflow、225项实时回归（205.861秒）和其余检查。初轮四套构建及签名/包内25项资源、Widget结构通过。
- 123首次安装流水5428，启动成功；Device Hub实际查看iPhone17 Pro/iOS27.0.1正式产品：正在聆听图标贴合顶部黑区、黑色外侧留白可见，不再占Face右上按钮行；按住Face启动聆听、点左图标展开“正在聆听”、收起均可见；状态退出后时间/信号/电量恢复。这是实际Face/聆听链路，不是合成夹具。未把静态截图当逐帧动画时序证据。
- 本轮实机检查追加发现单一聆听展开的160pt正文过空，因此继续改为内容行预算，单标题76pt，复杂详情与large/custom仍保留对应空间及滚动；移除无按钮时的空操作行，补充稀疏/完整/自定义/无障碍高度回归。最终构建、检查及二次安装结果见下。

最终四套iOS构建通过（/tmp/island-face-builds-accepted.log），真机构建通过（/tmp/island-face-device-accepted.log）。最后的check.sh返回1（/tmp/island-face-check-final.log）：157项UI、137项Workflow、225项实时回归（204.101秒）、其余包测试、Python/格式/边界/plist通过；959项集成中仅specialistPauseJoinsInferenceWhenChildCancellationDeliveryFails抛出expired，发生于编译并行阶段。未修改该用例或相关业务代码，空闲普通测试复跑结果另记。

编译结束后的普通测试空闲复跑返回0（/tmp/island-face-idle-recheck.log）：157项UI、959项集成及137项Workflow等全部通过；上述取消流程用例2.730秒通过，没有修改业务或放宽断言。最终边界、严格Swift格式、文档本地链接及git diff --check通过。完整check.sh的首次通过与最后一次单用例失败均保留，不把分阶段复测改写成最后全检退出0。

最终真机包签名、Widget入口/身份/版本和25项Skill资源校验通过；123二次原位安装流水5436，设备清单确认0.1.0/2026110123并启动成功（/tmp/island-face-{install-accepted,installed,launch-accepted}.log）。Device Hub复验单标题展开正文收紧至76pt，点击收起后设置页正常打开并可返回Face。截图保存在/tmp/island-face-123-{compact,expanded}.png；未纳入仓库。真实说话频谱、录像/倒计时业务、系统新展开布局、VoiceOver/Reduce Motion及功耗本轮未独立验收，未从静态截图推断逐帧动画性能。

## 2026-11-01 原生双呈现（122）

根据用户确认，同时接入ActivityKit/WidgetKit系统灵动岛与锁屏摘要，App内改为安全区内原生SwiftUI胶囊，删除Isle依赖、锁定记录和包内许可。参考1998code示例的扩展结构，不复制其图片、业务、定位/静音音频保活。现有Action、领域slot、业务按钮请求链继续复用；Task/倒计时/录像声明系统摘要，频谱与短暂状态留App内。

- 完整check.sh退出0（/tmp/native-island-check.log）：156项UI、959项集成、137项Workflow、225项实时回归（205.931秒），其余包测试、6项Python、边界、严格Swift格式及plist通过。后续内容去重、系统链接选择与展开计时布局修正后，24项Island UI及7项调用链集成再次通过（/tmp/native-island-targeted-postcheck.log）；最终严格格式与边界通过。新增5项系统呈现测试使用注入driver验证，不冒充原生系统权限/渲染证据。
- 初次iOS编译发现ActivityKit句柄没有Sendable标记；仅原生driver采用兼容导入，所有变更由单个主actor worker串行完成。修正后最终四套iOS构建全部通过（/tmp/native-island-builds-final.log）；App资源25项与新增Widget入口、bundle/version、URL scheme、Live Activity声明和旧SDK资源移除检查通过。实际Widget只编译共享摘要与Widget入口，无业务、设备、模型模块依赖。
- iPhone18 Pro / iOS27模拟器用临时受控测试入口链接真实UI.o和真实嵌入Widget（/tmp/IslandVisualCheck.swift）；没有调用相机/麦克风，频带为明确合成数据。App内左右22pt槽、频谱、外围点击计数0→1、点击展开/收起和真实回执2/2可见；20次更新最终只显示“测试摘要19”，回执29/29。最终展开附件与计时合为一行，计时完整可见。旋转设备外框仍保持产品竖屏方向，不声称开放或实测了产品横屏布局。
- 原生ActivityKit实际返回active；Device Hub看到系统紧凑leading图标/trailing计时、长按展开标题/说明/打开App链接，以及真实锁屏卡片。锁屏允许实时活动后卡片显示“状态已停止更新／打开App查看最新状态”，点击返回App并在重新投影后展开；与正常后台结束契约一致。系统日志记录Widget渲染batch success及后台end后60秒系统移除（/tmp/native-island-system-runtime.log）。另用终止无设备测试进程验证异常退出后系统紧凑展示随后被系统收回；不把异常退出展示当作业务后台继续运行。
- 临时测试入口已撤除，模拟器原位重装正式App，数据未卸载清空。正式App启动遇到配置/钥匙串保存失败（agents启动错误），因此本轮模拟器证据限于真实UI组件和真实Widget的受控内容，未据此宣称完整模型业务启动通过。真机arm64无签名构建及25项资源/Widget结构校验另已通过（/tmp/native-island-device-unsigned.log）。
- 第一轮真机签名失败：No Accounts及缺少dev.mobileharness.app.island profile（/tmp/native-island-device.log）。用户登录后重试签名成功（/tmp/native-island-device-signed.log），主包及Widget通过codesign --verify --deep --strict。122原位安装流水5420，设备清单确认0.1.0/2026110122，启动成功（/tmp/native-island-install.log、/tmp/native-island-installed.json、/tmp/native-island-launch.log）；Device Hub看到真实iPhone17 Pro的Face首页和完整状态栏，未操作用户麦克风/相机。原生系统岛/锁屏和App内频谱的动态验收仍限于上述模拟器受控内容。未验证真实音频/相机活动动效、VoiceOver/Reduce Motion真机交互或功耗，不从实现方式推断性能改善。

## 2026-11-01 第三方 Isle 视觉壳替换（121）

本轮依用户要求删除自绘岛身、形变曲线与果冻关键帧，直接依赖Isle提交a47b8cf62891c820729c9939660ac24094705202的IsleView。SDK拥有black surface、圆角、内边距及入退场弹簧；UI适配层持有场景、通用活动/交互、SwiftUI槽及完成回执，不采用SDK全局通知队列或Camera。SDK不是最流行的候选：GitHub查询时2 stars，选择依据是iOS源码/许可及自定义左右/展开槽；高关注候选分别为macOS组件或设计样例，未假称已接入其他库。

真实SDK模拟器探针发现：刘海/无cutout入场有三段UIView动画，CATransaction外层在约0.349s回调，50ms后transform仍为1.00956；据此改为SDK退场completion与入场原生层稳定观察，取消固定时长猜测。旋转时组件内部推进transition，拒绝原来的settled几何回执；回归测试覆盖这一情况。

在独立dev.mobileharness.island-validation测试壳链接真实UI.o/Isle.o（/tmp/IslandVisualCheck.swift），使用受控活动与合成频带，不调用相机/麦克风：紧凑左右各22pt、SDK外侧16pt、无下挂文字；实际点击左图标展开360pt卡片，测得SDK宽度195→373→360，回执2/2且无提前完成；展开时背景按钮计数成功增加；20次连续发布合并到最新“更新19”，最终回执21/21。测试壳临时开放横屏以验组件，产品当前iPhone入口仍为竖屏；不把测试壳旋转结果描述为产品横屏开放。

初轮四iOS构建在依赖图刚更新时ModelKitRuntime报“model objects have changed”，依赖解析完成后重跑四套通过（/tmp/isle-ios-final.log）；真机121构建、严格签名、25项业务资源及两包MIT原文副本检查通过。首次check.sh的150项UI、137项Workflow与225项实时回归通过，959项集成中一条投影夹具复用蓝牙阶段deadline导致倒计时断言超时；已改每阶段独立有界等待，不修改业务断言（/tmp/isle-check.log）。最终四套iOS构建通过（/tmp/isle-ios-verified.log），真机121最终构建通过（/tmp/isle-device-verified.log），两份resolved精确提交一致、包内MIT副本与原文一致。

最终原生模拟器复验：旋转时回执1/3→3/3，尺寸202→100且探针未见提前结算；快速替换后立即根重启最终47/47；动画期间失活后SDK视图为零，系统时间/Wi-Fi/电量重新显示，不伪造补齐被取消回执。独立测试壳已卸载，产品没有测试入口。

121原位安装流水5412，系统清单确认0.1.0/2026110121，未卸载或清理用户数据（/tmp/isle-install-final.log、/tmp/isle-installed-final.log）。启动被系统Locked拒绝，未声称完成真机视觉/业务验收（/tmp/isle-launch-final.log）。最终check.sh退出0（/tmp/isle-check-final.log）：151项UI、959项集成、137项Workflow、225项实时回归（206.116秒）及其余包测试、6项Python、边界/严格Swift格式/plist检查全部通过。旋转旧回执拒绝与每阶段独立等待的回归均通过。最终git diff --check和本轮文档本地链接检查通过。未执行真机观感、VoiceOver/Reduce Motion实机操作或功耗采样，不以SDK替换推断性能与能耗改善。


## 2026-11-01 灵动岛定向流体动画与完整附件（120）

本轮替代119的窄屏删右翼策略：有内容的一侧伸展，左右均保留22pt内容与12pt外侧黑色留白；侵入状态栏保留区时通过公开UIViewController偏好隐藏整条系统栏，收回后恢复。组件拥有布局、状态栏偏好和动效，业务接口不变。原生路径与图标mask同步拉伸、回缩、稳定，普通动效不使用岛身淡入。未引入第三方依赖。

- 定向19项UI与7项集成测试通过，覆盖完整左右槽、按需状态栏让位、单侧伸展、硬件收拢、弹性边界、版本/容量/迟到回执及既有业务调用链（`/tmp/island-fluid-tests.log`）。
- iPhone18 Pro / iOS27.0模拟器原生受控测试App链接实际UI组件，明确合成状态与频带、不调用相机麦克风。Device Hub实际显示完整左侧说话图标、右侧五柱频谱和外侧黑色边距；读取UIWindowScene.statusBarManager确认系统栏隐藏。切换单侧聆听后路径宽度184→160pt、系统栏恢复；再切加载状态，原生presentation路径采样171→199→194pt，最低不透明度1.0，右侧旋转加载指示可见，确认几何形变而非岛身fade。初次采样晚于动画启动，不据此推算完整起始帧或帧率。
- 点击展开后标题、说明和活动选择出现；收起后详情从可访问树移除。展开期间背景按钮从0到1，有限呈现回执5/5；收起完成回执6/6。该证据为合成内容下的实际UIKit呈现，不代替真实音频、真机观感、无障碍或功耗验收。
- 四个iOS Simulator构建通过（`/tmp/island-fluid-ios.log`）；最后小尺寸曲线修正后App增量构建及120真机构建通过（`/tmp/island-fluid-final-app.log`、`/tmp/island-fluid-device.log`）。两包各25项资源校验与真机严格签名校验通过。完整check.sh返回0（`/tmp/island-fluid-check.log`）：151项UITests、959项IntegrationTests（64.261秒）、137项AppWorkflowTests、225项LiveRuntimeTests（204.857秒）、其余测试、6项Python、严格格式、模块边界及plist检查通过。实时阶段没有并行构建。304条修改文档本地链接与最终git diff --check通过。
- 120版原位安装到iPhone17 Pro成功，流水5404；设备应用清单确认2026110120，启动请求成功（`/tmp/island-fluid-{install,installed,launch}.log`）。Device Hub实际看到产品Face待聆听画面、空闲系统状态栏可见；未据此声称真实说话/拍摄下的动画通过。模拟器独立测试App已卸载，产品构建产物已恢复，未保留演示入口或清除用户数据。

真实模型、真机动画观感、Reduce Motion设备操作和性能/功耗尚未验收。

## 2026-11-01 灵动岛组件内聚检查

范围：UI组件独占稳定slot身份/版本/容量及有限呈现完成；按钮改为有界id/title/value中立声明；领域适配通过窄协议发布；ApplicationControl白名单解释业务id，维持原请求链。底层布局/渲染器回执/等待接口为UI模块内部可见，测试用@testable合成回执，不开放给生产调用者。

- 定向回归18个UI测试与7个集成测试通过，覆盖任意自定义按钮、重复id及伪造value、过期交互、slot去重/根重置/容量、结束右侧非selected活动真实等待、无IslandState的协议替身、固定业务声明/白名单兼容和相机Gateway链。
- 实施中定向编译暴露过Agents不应直接引用Actions实现的问题；已撤回该引用，业务生产与消费仅共享中立按钮声明，独立白名单由集成测试约束。没有增加模块依赖或放宽边界规则。
- 四套iOS Simulator构建通过；将底层接口收为internal后，最终App再次增量构建通过，25项Agent/Skill资源校验通过。完整check.sh返回0：959项IntegrationTests（65.250秒）、150项UITests、137项AppWorkflowTests、225项LiveRuntimeTests（205.796秒），其余测试、6项Python、边界检查、严格格式及plist检查通过。真实模型评估未执行。最终git diff --check及文档本地链接核验通过。
- 本轮未改变外观、未重装真机；合成renderer/协议测试不等于原生动画、真实模型或设备验收。此前119安装记录不代表本轮代码已安装。

日志：`/tmp/island-cohesion-tests.log`、`/tmp/island-cohesion-ios.log`、`/tmp/island-cohesion-final-app.log`、`/tmp/island-cohesion-check.log`。


## 2026-11-01 灵动岛可读尺寸与自适应布局（119）

本轮替代118的对称固定宽度：主图标20–22pt、黑色外侧留白12pt，右侧附件仅在完整翼区可用时挂载；较窄屏幕保留左侧主状态，展开可查看附件。硬件估算中心不移动。参数是本App设计选择，不是Apple指定值；研究来源及约束见需求计划。

- 原生模拟器：iPhone 18 Pro / iOS 27.0，临时独立测试App链接实际UI组件，合成状态／频带明确标注、不调用相机麦克风。真实点击验证聆听／说话图标放大、外侧黑色边距、窄屏隐藏右侧谱；将模拟状态时间设置为23:59（该locale显示11:59），观察时间/信号/电量与头部无重叠。展开后显示完整标题、说明、五柱谱；收起后消失；背景计数按钮从0到1，回执从1/1到6/6。不是实际音频或功耗验证。临时App已卸载、状态栏覆盖已清除，产品构建包原始可执行文件和Info.plist已恢复。
- 四套iOS Simulator构建及MobileHarness真机构建通过；模拟器/真机各25项资源校验与真机严格签名校验通过。版本2026110119原位安装成功，安装序号5396，独立设备清单确认版本。系统启动因iPhone锁屏被拒绝，未声称本版真机观感通过。
- 自动化首次运行：针对性几何测试的CGFloat/Double直接比较断言失败（打印值相同）；改用显式转换后的坐标容差。完整check.sh随后出现既有slowTrackingDispatchExecutesOnlyTheNewestPendingTarget时间敏感用例失败（目标差值0.0207），其余结果与空闲复测在下方补充。没有修改跟随业务代码或放宽该断言。

复测结果：完整check.sh首轮返回1，仅上述跟随用例失败；边界检查、严格格式、6项Python测试、UI 147项、LiveRuntimeTests 225项（206.333秒）及plist通过。构建和原生测试结束后，完整普通测试阶段以 `swift test --skip 'LiveRuntimeTests|NativePresentationTests'` 空闲重跑返回0，IntegrationTests 957项（64.630秒）及UI 147项均通过，跟随用例本次2.794秒通过。没有修改业务代码来消除失败，不将首轮全检写成成功；真实模型评估未执行。最终 `git diff --check` 通过。

临时日志：`/tmp/island-readable-{tests,check,recheck,ios,device,install,installed,launch}.log`。真实机型状态栏布局、Reduce Motion与功耗仍需独立验收；模拟器合成频带不能证明真实声音效果。


## 2026-11-01 灵动岛外侧黑色留白

117版用户截图显示图标贴近胶囊外缘。UI内容框改为左槽靠右、右槽靠左，外侧至少8pt，内侧贴合估算硬件边界；图标等比适配、附件受同一宽度和裁剪限制。胶囊总宽、系统状态栏保留区与命中范围保持原契约。

专项2项测试函数通过，分别包含5种状态栏几何和6种外侧留白参数案例（/tmp/island-padding-tests.log）。Device Hub实际查看iPhone18 Pro模拟器的生产IslandHost：受控说话频谱与聆听图标的外侧可见黑色边距，未出现原有贴边；这仍是独立测试壳的合成状态，不代表真机业务或功耗验收。

真机构建、严格签名与25项资源检查通过（/tmp/island-padding-device.log）。2026110118已原位安装，流水5388，启动请求成功（/tmp/island-padding-install.log、/tmp/island-padding-launch.log）；设备应用清单核对见/tmp/island-padding-installed.log。四个iOS构建全部通过（/tmp/island-padding-ios.log），最终check.sh退出0：957项IntegrationTests（66.547秒）、225项LiveRuntimeTests（204.855秒）、其余测试、严格格式、边界、Python及plist校验通过（/tmp/island-padding-check.log）。模拟器测试壳已移除，产品包已恢复并通过25项资源复核；文档链接与git diff --check通过。最终真机观感仍以用户查看为准，未测量功耗。

## 2026-11-01 灵动岛视觉与左右槽修订

用户截图推翻115版的视觉完成判断：SwiftUI宿主重复安全区导致内容下推，210pt头部侵入状态栏。修订禁用嵌入宿主的safeAreaRegions，紧凑态仅左图标与可选右动画，文字和操作在安全区下展开；同级最新、独立左右活动及聆听／思考状态接入既有根状态和Actions。

首轮专项发现CGFloat／Double混合断言在Swift Testing宏中同值判假；改为显式Double转换与0.001pt几何容差后13项UI及5项集成通过（/tmp/island-redesign-tests-final.log）。新增右侧专用活动回归与最终完整检查单独记录。

使用/tmp/IslandVisualCheck.swift编译原生UI模块测试壳，独立dev.mobileharness.island-validation模拟器安装身份；明确受控状态与合成频带，不调用相机／麦克风，产品源码无演示入口。通过Device Hub实际点击iPhone18 Pro/iOS27：紧凑无文字且左右同一水平线；点击头部展开、收起后详情从可访问树移除；录制图标覆盖说话图标但展开选择仍保持；无右附件时右槽清空；展开时背景按钮计数从0变1，实际动画回执完成。该轮发现右侧距系统信号点过近，将左右保留区增至120pt、最大头部184pt，右槽按宽度缩窄五柱，低于18pt隐藏；收窄后的模拟器实际复验确认头部左右图标／五柱频谱／加载指示均留在岛内，系统时间与右侧信号／Wi-Fi／电量可见；展开与收起真实完成回执为3/3。测试壳没有产品业务成功含义，未以受控频带证明真实说话频谱或性能。

专项最终14项UI与5项集成测试通过（/tmp/island-redesign-targeted.log），覆盖新增右侧专用活动、rank/最新、左右选择、受限槽宽、频带降采样与既有按钮链。首次check.sh在严格格式阶段拒绝一处forEach写法，已改为等价for-in；完整复跑结果另记。

四iOS构建通过（/tmp/island-redesign-ios.log），最后收窄、44pt触摸区及右侧专用活动后的主应用模拟器／真机构建再次通过（/tmp/island-redesign-simulator-final.log、/tmp/island-redesign-device-final.log）。两包各25项资源通过，真机严格签名通过。2026110117原位安装到iPhone17 Pro，流水5380；系统应用清单确认0.1.0／2026110117（/tmp/island-redesign-install.log、/tmp/island-redesign-installed.log）。不卸载或清除用户数据。首次启动请求因Locked被系统拒绝（/tmp/island-redesign-launch.log）。随后Device Hub报告相机／麦克风使用期间不允许屏幕共享，无法从Mac读取这些业务状态的真机画面；已请求用户独立确认左右位置及展开文字。未将此环境限制写为视觉验收通过。模拟器专用测试壳已卸载，构建产物的产品身份／可执行文件已恢复并重新签名，25项资源复核通过。

最终check.sh退出0（/tmp/island-redesign-check-final.log）：957项IntegrationTests（68.892秒）、225项LiveRuntimeTests（204.207秒）、其余产品测试、6项Python测试、严格格式、模块边界及plist校验全部通过。实时回归未并行构建。修改Markdown本地链接与git diff --check通过。实际真机语音／拍摄状态观感、动态字体／Reduce Motion设备操作及功耗仍未验收，不由受控测试或构建推断。

## 2026-11-01 通用 App 内灵动岛

实现唯一UI根island、场景非key覆盖宿主及UI.Island呈现Action，迁移蓝牙／Task／回复频谱并接入Camera倒计时、录像和待处置。岛内取消倒计时／停止录像通过ApplicationControl转交既有Photographer→Gateway→固定Action，不创建第二套设备生命周期。根后台清理动画／等待与旧活动，业务事实由原领域拥有。

专项自动化通过：IslandState的容量、owner/revision/generation、主活动选择／手动固定、尺寸／动态字体、独立频谱、按钮过期、真实动画回执／打断／后台；集成覆盖Action参数、owner保护、实际约束尺寸返回、Skill别名及既有拍摄调用链。`/tmp/island-final-targeted.log`记录9项UI测试（几何含3参数案例）及21项相关集成／状态测试通过。账本回归确认结束后的旧present被拒绝；追加呈现目标替换回归后10项UI及4项Island集成专项通过（`/tmp/island-receipts.log`），实际几何随对应动画回执返回。所有renderer回执及设备操作均为明确替身，不代表UIKit／物理设备效果。

初轮四iOS构建通过（`/tmp/island-ios.log`），领域接入与生命周期完善后的四构建通过（`/tmp/island-ios-final.log`）。真机build2026110112编译、严格签名及25项包资源检查通过，原位安装流水5356；尝试启动因iPhone锁屏被系统拒绝（`/tmp/island-install.log`、`/tmp/island-launch.log`）。后续紧凑布局约束为210pt／44pt，回复频谱放在岛身外侧。首轮完整check.sh的225项实时回归通过（205.924秒），但有两项旧集成夹具失败：ApplicationControl固定旧Action数量、BehaviorEndpoint未绑定新增Island能力；已更新夹具，最终结果如下。

四个iOS构建MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero全部通过（`/tmp/island-ios-releasecheck.log`）。最终44pt点击区与岛身外回复频谱调整后，主应用模拟器及真机构建再次通过（`/tmp/island-simulator-accepted.log`、`/tmp/island-device-accepted.log`）；两包各25项资源及真机严格签名检查通过。build2026110115原位安装到iPhone17 Pro，安装流水5372，系统应用清单确认0.1.0／2026110115；本次系统启动请求成功（`/tmp/island-install-accepted.log`、`/tmp/island-installed-accepted.log`、`/tmp/island-launch-accepted.log`）。未卸载或清除用户数据，安装与启动不代替交互验收。

最终完整check.sh退出0（`/tmp/island-check-final.log`）：模块边界、6项Python测试、严格Swift格式、全部产品测试、956项IntegrationTests（65.371秒）、225项LiveRuntimeTests（206.213秒）和plist检查通过。实时回归期间未并行构建。修改文档的本地链接及git diff --check通过。Photography提示词36036字节，在38000预算内；Basic保持24971字节及原有常驻Action范围。

界面工具确认Mac锁屏；用户明确选择先完成自动化验证，未执行模拟器触摸／动画验收。待真机独立验证：硬件岛和状态栏避让、普通页面／sheet／Window层级、外围触摸与Face长按、展开／切换／自定义尺寸、最小化录像停止／倒计时取消、旋转／动态字体／Reduce Motion和回复频谱。性能与功耗未测量。

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

## 2026-11-01 系统灵动岛 Demo 适配（125）

用户22:04真机截图否定124自绘“窄脖子”轮廓；124不记为设计验收通过。125按用户最新要求撤掉App内IslandHost/Outline/Layout及自定义动画，只保留ActivityKit/WidgetKit。参考源码：1998code/iOS16-Live-Activities的WidgetDemo/WidgetDemo.swift、ContentView.swift和README；系统外壳与动画没有可复制的App内实现，而由iOS提供。原生分区适配真实Task/Camera/语音/连接摘要及现有导航。

重要验收边界：系统会决定紧凑/最小/展开及可见时长；App前台没有自绘替身，不能强制持续展开。Apple HIG说明自身App未使用时在Dynamic Island显示。任务新身份请求一次系统alert，普通进度不重复提醒；结束撤下任务。切出App后保留明确暂停摘要（无后台设备运行/频谱承诺），可长按验收原生展开；权限关闭、过期及用户移除分别处理。

本轮按用户要求不操作模拟器界面，build-ios.sh只编译四个目标。自动化使用替身验证提交/合并/权限失败/容量/身份/提醒去重/生命周期/白名单导航及Action和Skill链，不能替代系统动画验收。开发阶段初次专项命令误用Command Line Tools导致metal缺失，切到完整Xcode；迁移测试曾缺少probe声明，已补齐；首轮完整检查发现ApplicationControl Skill文案的禁用术语，已改为system request/alert。最终检查、构建和安装结果在本节后续记录。

最终结果：

- `./scripts/check.sh`已执行；首轮普通阶段唯一失败为Skill禁用术语检查，修复后完整普通阶段复跑通过：UI145、Integration959、Workflow137及其余普通包测试均通过，包含原生请求回执、阶段替换、旧快照解码等新增回归。基础边界检查、Swift严格格式检查及plist校验复跑通过。首轮串行LiveRuntime225项在空闲阶段全部通过，未重复无关设备时序测试。日志：`/tmp/island-native-check-final.log`（首轮结果，含已修复失败）、`/tmp/island-native-recheck.log`（修复后普通阶段完整复验，exit 0）；不能将首轮check.sh退出码1写成0。
- 最终源码`./scripts/build-ios.sh`四目标均BUILD SUCCEEDED，日志`/tmp/island-native-ios-final.log`；无模拟器界面操作。真机MobileHarness签名构建通过，版本2026110125，日志`/tmp/island-native-device-final.log`。
- 最终25个Skill资源、Widget可执行文件/身份/版本/支持标志/URL scheme校验通过，codesign --verify --deep --strict通过。开发中更早125包未安装；最终更新后的资源包安装后才记录下面版本。
- iPhone17 Pro（UDID尾号14C2401C）安装成功，安装序列5452，启动成功；devicectl读取已安装版本0.1.0 / 2026110125。日志`/tmp/island-native-install.log`、`/tmp/island-native-launch.log`、`/tmp/island-native-app-info.json`。
- 未代用户做真机视觉验收，未测量功耗/热状态。请用户验证：系统紧凑/长按展开/收回/状态栏避让，Task提醒及终态撤下，锁屏暂停/过期文案，返回相机/蓝牙/历史入口。系统前台可见性和展开时长由iOS决定，不能将Action submitted等同于已展开。


## 2026-11-01 App 内与系统双呈现恢复（126）

用户确认125桌面系统灵动岛可见、App内不可见；最新明确要求两者同时提供。126恢复前台通用组件，两端共享主状态和目标详情数据。展开内容仅为目标图标和目标描述；普通状态保持紧凑，任务开始展开、结束收回。同阶段进度不抢回手动收起状态，拍摄/说话主图标变化不删除目标详情。系统权限失败与前台呈现独立。

App内外壳采用单一标准圆角矩形连续伸缩，取消旧窄脖子造型；UIKit动画完成按代际和版本回执，组件拥有图标、加载、录制及实际频谱效果。状态栏保留，紧凑左右等宽槽和黑色边距；系统外壳/位置/动画由iOS管理，不宣称App内动画与系统私有实现完全一致。前台位置依据公开安全区约束推导，仍需该机型实测。

自动化：最终完整`./scripts/check.sh`返回0；UI150、Integration959、Workflow137、串行LiveRuntime225及其余默认目标通过，边界、严格格式、Python和plist检查通过。覆盖详情新阶段/更新/收起/终态、普通内容无详情、并发主图标与详情独立、后台保留共享目标摘要、原生权限失败、本地迟到回执、实际频带不提交原生更新以及Action/Skill链。日志`/tmp/island126-check.log`；专项日志`/tmp/island126-targeted.log`。

按用户要求不进行模拟器界面验收。构建检查和替身测试不代表真实动画、硬件边缘、状态栏避让或功耗验收。真机重点：App内聆听图标可见、说话右侧频谱、目标自动展开与终态收回、左右留白、窗口触摸透传、切回桌面系统岛及长按详情、Reduce Motion。

最终构建与安装：`./scripts/build-ios.sh`四个iOS目标全部成功，最后增量复验日志`/tmp/island126-ios-verified.log`；真机签名构建成功，日志`/tmp/island126-device-verified.log`。25项Skill资源、Widget可执行文件/身份/版本/支持标志/返回URL校验及严格深层签名校验通过，`git diff --check`通过。

iPhone17 Pro原位安装成功，安装序列5460；系统启动请求成功，独立应用清单确认0.1.0 / 2026110126。日志`/tmp/island126-install.log`、`/tmp/island126-launch.log`、`/tmp/island126-app-info.json`。未卸载或清空用户数据，未代用户验收真机视觉，未测量功耗。


## 2026-11-01 边距与展开收起（127）

紧凑内边距15→10pt，总宽200→190pt；展开正文横向24→16pt、图文间距14→10pt、底边24→14pt，保留字体/图标尺寸与硬件保护区。系统Widget仅缩减自有内容间距，系统外壳仍由iOS决定。前台增加44pt收起按钮及整个展开区的上滑收起（至少36pt，垂直超过水平1.5倍）；二者复用现有状态及动画，任务不被结束，同阶段更新不自动重开。

公开API依据：[UIWindow.Level.alert](https://developer.apple.com/documentation/uikit/uiwindow/level/alert)说明此层级窗口显示在状态栏上方。前台展开跨状态栏时使用此层级，收起动画实际完成后恢复normal+1；保持非key、透明区域透传，不禁用系统状态栏，不访问系统图标。该文档依据不能替代当前iOS27真机覆盖/隐私指示和系统手势验收。

本轮不操作模拟器界面。新增回归验证手势方向/边界、紧凑等边距及保护区、展开层级意图；按钮真实命中、ScrollView中上滑收起、状态栏覆盖与收回后的恢复、动画打断待用户真机验证。

构建与安装：build-ios.sh四个目标全部成功（`/tmp/island127-ios.log`），最终真机签名构建成功（`/tmp/island127-device-final.log`）。25项Skill资源、Widget身份/可执行文件/版本及返回URL校验、严格深层签名和diff格式校验通过。原位安装到iPhone17 Pro成功，安装序列5468，系统启动成功，应用清单确认0.1.0 / 2026110127（`/tmp/island127-install.log`、`/tmp/island127-launch.log`、`/tmp/island127-app-info.json`）。没有清空用户数据，尚未由助手做真机视觉验收。

最终完整`./scripts/check.sh`返回0，UI151、Integration959、Workflow137、串行LiveRuntime225及其余默认测试通过；模块边界、Python检查、严格Swift格式和plist检查通过。日志`/tmp/island127-check.log`。构建期间UI最后一处HStack显式spacing=0修正已做严格格式复核，并重新完成最终真机增量构建；真实触控和覆盖行为不由这些测试证明。


## 2026-11-02 内容接口与展开交互重构（128）

执行已确认计划：左右指标可分别配置符号预设、loading、实际频谱或进度；紧凑18pt、展开24pt、文字15pt且支持字体缩放。detail仅文字/图片引用，主图标与紧凑共用primary；有效详情首次出现自动展开，收起只隐藏，普通更新保留偏好。优先级改为整体活动切换，低优先内容及偏好保留。系统紧凑区无文字/数字计时，图片本轮仅App内。

专项测试`/tmp/island128-targeted-final.log`通过：UI23项、Integration7项，包含新增真实ImageIO缩放、纯图片/图文详情、资源归属/绑定/替换/容量/取消/清理、整体抢占恢复和旧数据解码。后续新增指定活动收起回归及缺失primary拒绝，结果随最终检查记录。没有模拟器界面操作，未代用户验收真机视觉。

真机待验收：左右图标和字体尺寸；目标默认展开、点击/箭头/上滑收起以及点击紧凑恢复；高优先录像接管并恢复任务偏好；系统侧同步图标/文字、状态栏覆盖与收回。图片框架自动化使用测试图片，没有给产品加入演示窗口或自动将拍照缩略图搬到灵动岛。

完整`./scripts/check.sh`返回0：UI154、Integration960、Workflow137、串行LiveRuntime225及其他默认目标通过，边界/格式/Python/plist检查通过，日志`/tmp/island128-check.log`。执行过程中最后收紧缺失primary的解码与UIFont字重匹配，另做最终专项复验与增量构建，分别记录以下结果；不将编译结果当作真机动画验收。

最终增量专项`/tmp/island128-regression.log`返回0（UI23、Integration8）；边界复查`/tmp/island128-boundaries-final.log`、修改文件严格格式和diff校验通过。最终四个iOS目标均BUILD SUCCEEDED（`/tmp/island128-ios-verified.log`），真机签名构建2026110201成功（`/tmp/island128-device-verified.log`）。25项Skill资源、Widget可执行文件/身份/版本/支持标志/URL scheme，以及严格深层签名校验全部通过。

已原位安装到iPhone17 Pro，安装序列5476；独立应用清单确认0.1.0 / 2026110201。日志`/tmp/island128-install.log`、`/tmp/island128-app-info.json`。启动请求被系统以Locked拒绝（CoreDevice10002 / FBSOpenApplication7），没有运行时闪退证据；`/tmp/island128-launch.log`保留原因。未卸载或清空数据，用户解锁后可自行打开验收；不能记录为已启动或视觉通过。


## 2026-11-02 紧凑岛高度与横向对齐（129）

用户00:31:59（App内）与00:32:21（桌面）两张1206×2622截图作为位置对照。以黑色RGB≤2测量，App翼部约y31...148、系统约y41...152；左图标青色边界App约x358...397/y62...118、系统x362...402/y68...126。系统辅图标中心约824px、左图标中心约382px。该阈值受描边/抗锯齿影响，不当作系统原生frame查询。未复制用户截图进仓库。

依据Apple HIG Live Activities紧凑区域36.67pt高度与公开两翼预算，组件使用110/3pt高、376/3pt中央保护区。当前SDK WidgetKit.swiftinterface有contentMargins及isDynamicIslandLimitedInWidth；检查UIKit/WidgetKit接口未发现供App读取完整岛frame的API，也无本机可用的reservedRegions接口。定位是安全区与截图校准：safeTop−48，该402pt设备顶部14pt。22pt槽直接邻接中央保护区，外侧5pt留白，双翼179.33pt；计算中心为382/824px。单左图标无空右翼，固定硬件中心，紧凑进出/附件增减只改变横向尺寸。

参考：[Apple Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities)、[WidgetKit contentMargins](https://developer.apple.com/documentation/widgetkit/dynamicisland/contentmargins(_:_:for:))。36.67为官方紧凑区域尺寸；顶部/外侧边距为该设备校准值，不宣称所有机型通用或系统实时返回。系统原生外壳和边距未重设，字号仍共用18pt。

首轮自动化出现4处几何断言失败：引入1/3pt精度后用Double严格相等比较边界和对称留白。已改为0.001pt误差检查，远小于一个物理像素；新增两槽中心、单侧/双侧相同高度和硬件不移动断言。首轮结果保留`/tmp/island129-check.log`，最终复验另记。按用户要求不操作模拟器界面；本轮尺寸图像分析不能替代修复后的真机验收。

最终结果：`check.sh`首轮退出1，失败仅上述4处严格浮点几何断言；该轮Integration960、Workflow137、串行LiveRuntime225及其余默认检查通过。修正后完整Island专项复验返回0（UI24、Integration8，`/tmp/island129-regression.log`），覆盖所有失败断言及最终22pt槽/5pt外边距的中心对齐；不将首轮check退出码记录为0。修改文件严格格式及diff校验通过。

最终`build-ios.sh`四个目标全部成功（`/tmp/island129-ios-final.log`），真机签名构建2026110202成功（`/tmp/island129-device-final.log`）。25项Skill资源、Widget可执行文件/身份/版本/支持标志/返回URL，以及严格深层签名校验通过。

真机原位安装成功，序列5484；系统启动请求成功，独立应用清单确认0.1.0 / 2026110202。证据：`/tmp/island129-install.log`、`/tmp/island129-launch.log`、`/tmp/island129-app-info.json`。未清空用户数据。新包的真实视觉尚待用户确认，未测量帧率/功耗。


## 2026-11-02 收起重开、详情居中与相机初始位置（130）

用户00:59:45截图反馈收起后不能重开、详情短文偏上/贴边、相机标题与展开岛交叉。代码定位：IslandAnchor命中直接排除中央protected区域，紧凑后恢复normal+1让系统状态栏先接收触摸；详情HStack.top加满高ScrollView令短文顶部对齐。此次移除中央触摸排除，带详情的紧凑活动保留alert层级，透明/圆角外仍透传。详情改center及ViewThatFits自然高度短文/长文滚动，左右24pt。图像窗口竖屏安全区顶预留80pt等比fit，不随岛状态自动移动用户窗口。

- `./scripts/check.sh`：exit0，UI157、Integration960、Workflow137、LiveRuntime225等全部通过；LiveRuntime206.341s。新增回归验证左右槽与中央点击命中、手动收起后内容保留和重开、圆角外透传；相机402×778安全区初始位置在普通展开岛下方至少12pt，底部不越界且比例不变。日志`/tmp/island130-check.log`。
- `./scripts/build-ios.sh`：exit0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero四项BUILD SUCCEEDED；只构建，未操作模拟器界面。日志`/tmp/island130-ios.log`。
- 真机Debug签名构建`CURRENT_PROJECT_VERSION=2026110203`：exit0；25项Agent资源、Widget嵌入/身份/版本/标志/URL校验通过，codesign --verify --deep --strict通过。日志`/tmp/island130-device.log`。
- devicectl安装到`00008150-000579D114C2401C`成功，databaseSequenceNumber5492；launch成功，apps查询版本0.1.0/2026110203。日志`/tmp/island130-install.log`、`/tmp/island130-launch.log`、`/tmp/island130-app-info.json`。
- 真机视觉与手势待用户验收：紧凑岛中央/两端点击重开、短文字和主图标中心线、两侧留白、相机默认标题不与普通展开岛交叉。长文字/动态字体导致更高展开区、手动移动和最大化仍可重叠；不承诺所有窗口始终避开岛。自动化不等于UIKit真机触摸或动画验收，无性能/功耗测量结论。


## 2026-11-02 ASR异常后恢复聆听（131）

用户01:30:07截图中SFSpeechErrorDomain code1 RecogRejected后首页/灵动岛仍processing。定位SpeechPerceptionAgent.finishUtterance在等待ASR finish前发布processing；recoverRecognition仅写本地phase=.listening，既未更新Context也未发UI工具/empty终态。并非识别失败已提交LLM。修复复用统一transition(.empty)，清空/封口失败字幕、释放识别轮次绑定；保留原始错误，采集代/运行态/许可/暂停门仍控制恢复，不新增设备开启路径。

- 定向语音回归：ASR创建失败与finish后返回合成RecogRejected两种case均通过，确认失败后Context/listening、listening工具、字幕封口、empty事件及下一句final成功。初次测试代码使用错误的emitter/ToolCall字段导致编译失败，改为现有fail/arguments API后通过；日志`/tmp/asr131-regression.log`、`/tmp/asr131-regression-final.log`。这些是能力替身，不是Apple服务真机测试。
- 最终`./scripts/check.sh`：exit1。Integration960（含上述2case）、UI157、Workflow137、LiveRuntime225（203.758s）等通过；NativePresentationTests中的cameraNativeMetalDrawStopAndLayerHandoff在CameraFramePresentationTests.swift:208等待5秒超时，属于本轮未改的相机原生渲染测试。日志`/tmp/asr131-check.log`。
- 单独复跑NativePresentationTests及该相机测试，两次命令exit0，但日志停在该测试started、没有完成摘要，均不认定测试通过。日志`/tmp/asr131-native-recheck.log`、`/tmp/asr131-metal-recheck.log`。不更改测试、阈值或相机实现来规避此问题。
- 四项iOS构建全部成功（exit0），未操作模拟器界面；日志`/tmp/asr131-ios.log`。真机Debug签名构建2026110204成功（exit0），日志`/tmp/asr131-device.log`；Agent25资源、Widget嵌入/身份/版本/支持标志/URL校验及codesign --verify --deep --strict通过。
- devicectl安装到00008150-000579D114C2401C成功，databaseSequenceNumber5500，launch成功；日志`/tmp/asr131-install.log`、`/tmp/asr131-launch.log`。用户真机验收仍需确认Apple ASR真实拒识后页面和岛恢复聆听、下一次VAD可识别；无性能/功耗结论。


## 2026-11-02 聆听策略空闲回执循环（132）

根因：VoiceSessionCoordinator.applyListening关闭分支请求取消回复；AgentChatWorker取消后发布递增revision的ReplyActivity；SpeechPerception.receiveListening把每条新事实无条件转换为Speech.Listening.update，形成关闭→取消回复→空闲事实→关闭。修复只在ReplyActivity导致聚合paused实际变化时提交策略，来源版本/代际和pendingFinal确认仍正常推进。显式开关不受去重影响，没有隐藏日志、限频或定时器。

- 定向5项回归通过（含ASR失败参数化2case）；日志`/tmp/listening132-regression-final.log`。首次编译遇到Testing宏对allSatisfy keypath的rethrows错误，改为等价闭包后通过，未改变断言语义。
- 完整检查新增三项：六次toggle＋四来源768条递增空闲事实仅六次Action；聚合忙碌/释放只产生一次暂停和一次恢复；关闭输出后注入空闲反馈，下一条Action必须来自新的用户开启输入而非反馈自发关闭。这些均通过，日志`/tmp/listening132-check.log`。不等于物理长按/真实麦克风测试。
- `./scripts/check.sh` exit1：Integration963项中residentNativeStateSeedsOnceAndReadsNeverSampleSources等待失败，其余（含新增与此前ASR回归）通过；UI157、Workflow137、LiveRuntime225（204.073s）等通过。该平台状态测试单独复验exit0、1/1通过（0.009s），日志`/tmp/listening132-platform-recheck.log`。NativePresentationTests在相机Metal测试started后无完成摘要，不能认定原生渲染通过；不修改无关测试或阈值。
- `./scripts/build-ios.sh` exit0、四项BUILD SUCCEEDED，日志`/tmp/listening132-ios.log`。真机Debug签名构建2026110205成功，日志`/tmp/listening132-device.log`；25项Agent资源、Widget嵌入/身份/版本/标志/URL与codesign --verify --deep --strict通过。未操作模拟器界面。
- 安装到00008150-000579D114C2401C成功，databaseSequenceNumber5508，日志`/tmp/listening132-install.log`。首次启动因锁屏被系统拒绝（`/tmp/listening132-launch.log`）；用户继续后重试启动成功（`/tmp/listening132-launch-retry.log`）。真机连续长按切换后内部日志是否停止增长仍由用户验收，未声称已手动测试。


## 2026-11-02 后台连续语音与同源灵动岛（133）

- 已实现Scene可见性与根运行生命周期分离：持续的Model/Platform/UI/Actions/Gateway/Agents不因切后台而invalidate；Actions关闭并加入相机/前台设备服务，Agents加入视觉停止，窗口与App内岛停渲染。已开启的语音、模型回复、通用Action和同一系统岛活动仍由原owner持有。用户关闭、系统中断、根停止保持真实清理。回复半双工保留原生录音代，仅VAD/ASR准入关闭并丢弃抑制帧；没有静音播放保活。
- 首轮check被静态规则中旧UI/model setForeground绑定要求阻断；更新边界校验到新的Scene/持续运行契约。生命周期测试首轮末尾事件断言未过滤invalidate，改为检查实际stop事件顺序。最终`/tmp/background133-check.log`退出0：Integration 963项、UI 158项、AppWorkflow 138项、LiveRuntime 225项均有通过摘要。新增后台生命周期与同源岛状态测试通过；既有原生序号/准入门控、ASR错误恢复和聆听回执循环回归通过。
- 原生测试证据限制：NativePresentationTests中cameraNativeMetalDrawStopAndLayerHandoff仅有started，无测试或suite完成摘要；即使脚本退出0，也不将该项记为通过。未操作模拟器界面。
- 补充sceneBackgroundPreservesRunningActionsAndPreparedTickets通过（`/tmp/background133-actions.log`，1项）：后台不取消在途请求，保留预备票据并允许新请求，执行原生场景停止；完整invalidate继续拒绝新执行。补充测试Swift格式检查和git diff --check通过。
- scripts/build-ios.sh四项构建通过（`/tmp/background133-ios.log`）；真机Debug签名构建2026110206通过（`/tmp/background133-device.log`）。最终App的25项Agent资源和Live Activity扩展身份/版本/入口校验通过，codesign --verify --deep --strict通过，Info.plist确认UIBackgroundModes仅含audio。
- 安装尝试失败（`/tmp/background133-install.log`）：CoreDeviceError 4016，设备00008150-000579D114C2401C显示unavailable；已请求用户连接并解锁。2026110206尚未安装，不能宣称后台或锁屏实测成功。
- 待真机：前台开启聆听→桌面/锁屏连续多轮ASR、慢模型回复及TTS；期间系统岛阶段变化、回App内容一致；用户关闭/系统音频中断后不自动复活；前台相机/跟随后台关闭，前台受限Action明确失败。CPU语音路径及云端模型为本次主要路径，iOS不保证进程被终止后继续运行，本地GPU推理不承诺后台可用。Live Activity本身不授予后台执行时长。


## 2026-11-02 聆听右侧计时（134）

- 通用IslandIndicator新增elapsed(startedAt:)，App与Widget共用IslandElapsedView：16pt等宽数字、44pt槽、原生分钟/秒计时。中央硬件区、高度和5pt外侧边距不变，无逐秒Action/ActivityKit更新。组件只解释通用日期；聆听适配器维护连续阶段的起点，其他领域更新/前后台/高优先级遮挡不重置，离开再进入聆听重计。
- 新增UI日期编码/非法日期及固定高度/硬件贴合回归、Integration连续阶段起点回归。完整check脚本退出0（/tmp/island134-check.log）：Integration 965、UI 159、AppWorkflow 138、LiveRuntime 225项均有完成通过摘要。NativePresentation的cameraNativeMetalDrawStopAndLayerHandoff仍仅有started，无完成摘要，不计为通过。没有操作模拟器界面。
- 原生计时API依据：[Apple Text(timerInterval:pauseTime:countsDown:showsHours:)](https://developer.apple.com/documentation/swiftui/text/init(timerinterval:pausetime:countsdown:showshours:))。两端传同一日期，不靠每秒推送数字。
- 真机2026110207首次签名构建及资源校验成功；安装尝试CoreDeviceError 4016，设备仍unavailable（/tmp/island134-install.log），未安装或进行视觉验收。最终可访问性标签使用通用“已用时间”，不在基础组件引用聆听业务。

- 最终四项iOS构建全部通过（/tmp/island134-ios-final.log），2026110207真机签名构建通过（/tmp/island134-device-final.log），25项Agent资源、Widget入口/身份/版本以及codesign严格验证通过。git diff --check通过。最终构建只补充通用无障碍标签；不改变此前测试覆盖的计时/阶段/布局逻辑。


## 2026-11-02 灵动岛文件归并与职责整理（135）

- 范围仅UI/Actions灵动岛及其构建/文档/回归。源文件9→8：删除独立IslandLiveActivity、IslandPresentationService文件，将系统driver合入IslandSystemPresentation，通用Action/参数/绑定/执行合入IslandActions；新增共享IslandIndicators替换两个宿主重复绘制。IslandActivityAttributes集中纯内容与兼容快照，IslandState管理状态/资源，IslandHost持有布局与手势，IslandDomainPresentation保留领域投影。未新增目录、第三方依赖或接口层级。
- 删除IslandMotion与large/custom枚举、自定义宽高/动画存储及Action目录参数。旧请求在纯入口拒绝；保留已安装版本的最小旧快照/内容解码，不保留旧渲染实现。Widget源边界改为内容/指示器/Widget入口三文件，仍无业务/设备/模型模块依赖。
- 首轮check（/tmp/island135-check.log）退出1：新增目录参数测试误用ActionFunction.parameters，改为检查宏生成ActionDeclaration.parameters后编译通过；同轮LiveRuntime 225项通过（203.773秒）。NativePresentation中cameraNativeMetalDrawStopAndLayerHandoff只有started，无完成摘要，不计通过。
- 修正后的完整非实时测试阶段（/tmp/island135-functional-final.log）UI159、AppWorkflow138项通过，Integration966项中965通过，平台residentNativeStateSeedsOnceAndReadsNeverSampleSources报invalidSnapshot等待失败。该项单独复验（/tmp/island135-platform-recheck.log）1/1通过0.009秒。不得将首轮check或复验前的整套结果描述为全通过。
- 灵动岛相关测试通过：新目录仅activityID/size、过时几何/动画拒绝、内容编码/图片/展开状态、计时起点/后台一致/固定高度等。最终边界检查、全源码Swift格式检查、git diff --check通过（/tmp/island135-boundaries.log、/tmp/island135-format.log）。
- 真机2026110208最终签名构建通过（/tmp/island135-device-delivery.log）；25项Agent资源、Widget入口/身份/版本、codesign --verify --deep --strict通过。安装失败CoreDeviceError4016，设备unavailable（/tmp/island135-install.log）；未安装或实测UI外观，不操作模拟器界面。

- 最终scripts/build-ios.sh四项iOS构建全部通过（/tmp/island135-ios-delivery.log，退出0）；覆盖最后的文件归并、共享指标绘制与尺寸扩展移动。

- 后续用户请求安装：iPhone恢复connected，2026110208安装成功（bundle dev.mobileharness.app，databaseSequenceNumber 5532），devicectl启动成功。包含133后台连续对话、134聆听计时及135整理；这里只确认安装/启动，不代表后台音频、视觉或手势实机验收通过。


## 2026-11-02 UI目录归档与共享机制整理（136）

- 用户批准Root、Shared、Components/Island和Components/Window四个目录。迁移19个源文件；UI根只保留UIContainer.swift。导航、共享呈现凭证与State快照从根文件拆出；功能输入回执移回对应Conversation/Camera/Settings owner。Face原生眼睛、光环和Metal资源归Conversation；不新增target、模块或依赖，不修改公开接口及运行行为。
- 全仓引用核对后删除UIRequests.cancelOutstanding、UIDiagnosticsContainer.audioDetectionPresentation、ActionActivityState.hasOngoingTask三个未使用成员；保留系统运行时回调和既有Live Activity快照兼容。技术README按归属迁移，四个新目录均有README；UI/总体技术文档本地链接、旧源路径不存在、Xcode源引用、Shared无具体功能输入类型及git diff --check通过。
- 首轮静态检查发现foundation错误owner校验仍拼接旧UI/UIFailure.swift路径（/tmp/ui136-boundaries.log），更新为Shared/UIFailure.swift并保留唯一编译owner验证。最终完整./scripts/check.sh退出0（/tmp/ui136-check.log）：UI159、Integration966、AppWorkflow138、LiveRuntime225项有通过摘要；LiveRuntime耗时206.317秒。Swift格式、架构边界、Python六项测试和plist校验通过。
- NativePresentationTests的cameraNativeMetalDrawStopAndLayerHandoff仅有started，没有测试或suite完成摘要；脚本退出0不代表该项通过，本轮仍未确认。没有操作模拟器界面，也未进行真实模型、设备交互或性能功耗验收。
- ./scripts/build-ios.sh退出0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero四项BUILD SUCCEEDED（/tmp/ui136-ios.log）。真机Debug签名构建2026110209成功（/tmp/ui136-device.log）。25项Agent资源、Live Activity扩展入口/身份/版本/声明、codesign --verify --deep --strict通过；确认迁移后的ListeningHalo仍编入HarnessKit_UI.bundle/default.metallib。
- devicectl安装到00008150-000579D114C2401C成功，databaseSequenceNumber5540（/tmp/ui136-install.log）。启动被锁屏拒绝，CoreDeviceError10002/Locked（/tmp/ui136-launch.log）；未声称已启动或完成真机视觉验收。用户解锁后可手动打开2026110209。本轮未commit，保留工作区其他修改。


## 2026-11-02 UI模块契约归位（137）

- UIFailure和UIStateSnapshot从Shared归回UI根，UIFailureReporting/UIContainerError合入UIFailure；Shared保留请求回执和呈现接纳机制。Root仍为根页面组合，子能力和其他模块未迁移。AGENTS.md明确“根目录放模块入口和整体契约；Shared／Support放可复用机制；具体能力跟随所属目录”，同时要求保留编译目标边界，不依public、引用次数或根文件数量机械分类。
- Xcode引用、统一Failure根owner、StateSnapshot路径和技术README同步；移除只允许单一根文件的检查，改为模块入口/契约唯一归属校验。旧Shared文件路径不存在，UI及总体技术文档本地链接、git diff --check通过。公开类型、错误schema、快照编码及运行逻辑未变。
- ./scripts/check.sh退出0（/tmp/ui137-check.log）；UI159、Integration966、AppWorkflow138、LiveRuntime225项均有通过摘要，实时组205.414秒。边界、Swift格式、Python与plist校验通过。NativePresentationTests中的cameraNativeMetalDrawStopAndLayerHandoff仍仅有started，无完成摘要，不认定原生相机测试通过。
- ./scripts/build-ios.sh退出0，四项BUILD SUCCEEDED（/tmp/ui137-ios.log）。真机Debug签名2026110210构建成功（/tmp/ui137-device.log）。25项Agent资源、Widget入口/身份/版本/声明及codesign严格校验分别退出0（/tmp/ui137-agent-resources.log、/tmp/ui137-island-resources.log、/tmp/ui137-signature.log）。
- 安装到00008150-000579D114C2401C成功，databaseSequenceNumber5548，随后launch成功（/tmp/ui137-install.log、/tmp/ui137-launch.log）。未操作模拟器界面，未进行真机手势/后台多轮或性能功耗验收。本轮未commit，保留其他工作区修改。


## 2026-11-02 紧凑灵动岛覆盖状态栏（138）

- 根因是IslandHost将无详情紧凑态初始化为normal+1，并在动画完成后再次降至normal+1；聆听计时不带详情，因而被系统信号图标盖住。改为显示前固定alert，整个挂载周期不再修改层级；删除coversStatusBar派生值及两个过时测试断言，保留几何/命中/展开/抢占/后台回归。不更改Action、计时宽度、系统Live Activity或系统状态栏可见性，非key和透明区域透传保持。
- 平台依据Apple UIWindow.Level文档的normal/statusBar/alert顺序：https://developer.apple.com/documentation/uikit/uiwindow/level 。应用层级修复不等于已验证真实系统合成，也不承诺覆盖隐私指示器和所有系统保护界面。
- ./scripts/check.sh退出0（/tmp/island138-check.log）：UI159、Integration966、AppWorkflow138、LiveRuntime225项有通过摘要，实时组205.950秒；架构、Swift格式、Python和plist检查通过。NativePresentationTests中的cameraNativeMetalDrawStopAndLayerHandoff仅started，无完成摘要，不计为通过。git diff --check通过。
- 四项iOS构建通过（/tmp/island138-ios.log），真机Debug签名构建2026110211通过（/tmp/island138-device.log）。25项Agent资源、Widget入口/身份/版本/声明与codesign严格验证均退出0（/tmp/island138-agent-resources.log、/tmp/island138-island-resources.log、/tmp/island138-signature.log）。没有操作模拟器界面。
- 安装到00008150-000579D114C2401C成功，databaseSequenceNumber5556（/tmp/island138-install.log）。首次launch连接立即断开CoreDeviceError4000（/tmp/island138-launch.log）；设备再次显示connected后重试Network.NWError60超时（/tmp/island138-launch-retry.log）。只能确认安装，不能确认启动或UI验收。
- 真机待验收：无详情聆听计时不被信号图标压住、任务展开后收起及录像/语音抢占不降层、前后台重建保持覆盖、岛外时钟/电量等保留、岛外触摸正常。自动化不证明UIKit真实覆盖及手势结果，无性能功耗结论。本轮未commit。


## 2026-11-02 App内灵动岛默认系统状态（139）

- 新增Components/Island/IslandStatusBar.swift：UI中立IslandDeviceStatus/只读构造端口、单一显示刷新owner、纯布局和UIKit时间/网络/电池视图。PlatformKit提供既有power/network驻留事实的PlatformSystemStatus类型化投影，App仅字段适配；UI无平台依赖、设备采样、权限申请或第二套监测。系统状态不加入IslandContent、Action声明或Skill参数。
- 实际本地挂载后隐藏原系统状态栏；退出动画完成拆卸、后台及失活恢复。左时间右网络/电量，36pt默认外边距向12pt压缩，仍不足从内侧网络开始隐藏，再电池；左时间自身无法容纳时隐藏。业务几何不缩小。展开顶部保留硬件区、正文独立；未知电量不当0，读取失败清空为未知并按失败周期报告一次。组件显示刷新每5秒读缓存，分钟边界提前刷新时间；后台/拆卸取消，无逐秒Action或系统Live Activity更新。
- 首次定向编译发现新IslandSystemStatus命名与既有系统活动状态枚举冲突，改为IslandDeviceStatus（/tmp/island139-focused.log）。修正后5项定向测试通过（/tmp/island139-focused-final.log）；含6种视口参数、挤压后隐藏顺序、实际挂载生命周期、失败清空/报告去重、非法电量和路径类型语义。
- 首轮check在静态Xcode归属检查失败：新源文件导航引用误插入Actions/UI同名组；改回UI组件组，编译target未变化（/tmp/island139-check.log）。最终check退出0（/tmp/island139-check-final.log）：UI163、Integration967、AppWorkflow138、LiveRuntime225项有完成通过摘要，实时组206.065秒；Swift格式、架构、Python和plist检查通过。NativePresentation的cameraNativeMetalDrawStopAndLayerHandoff仅started，无完成摘要，不计通过。
- 最终补充快速失活/恢复但宿主未销毁时的幂等挂载确认，不重复写入可观察标志或启动刷新。两个挂载/失败恢复测试复验通过（/tmp/island139-mount-final.log），Host格式及git diff --check通过。最终四项iOS构建全部成功（/tmp/island139-ios-delivery.log），真机Debug签名2026110213构建成功（/tmp/island139-device-delivery.log），已确认IslandState对象产物晚于最终源码。25项Agent资源、Widget入口/身份/版本/声明及codesign严格校验分别退出0（/tmp/island139-agent-delivery.log、/tmp/island139-island-delivery.log、/tmp/island139-signature-delivery.log）。
- 中间版2026110212安装成功但启动连接断开。最终2026110213安装到00008150-000579D114C2401C成功，databaseSequenceNumber5572（/tmp/island139-install-final.log），随后启动成功（/tmp/island139-launch-final.log）。
- 未操作模拟器界面；真实状态栏隐藏/恢复、模态页面、左右位置、伸缩避让、旋转和前后台视觉仍待用户真机验收。网络表示路径类型/离线，不表示信号强度或远端服务可达；系统隐私指示器不可由App控制，无性能功耗结论。本轮未commit。


## 2026-11-02 系统状态与业务共用岛身（140）

- 将系统状态条从overlay根移入黑色surface，与业务共用裁剪、圆角和UIViewPropertyAnimator；使用父子坐标转换保留中央业务位置，打开、展开、收回及打断一起处理。紧凑高度仍110/3pt，实际外壳左右16pt、最大420pt；统一16pt内边距，空间不足同步压缩至10pt，再隐藏内侧系统元素。未改变Action接口、设备事实来源或系统Live Activity。
- 删除38pt实心电池标签，改为28×14pt轮廓、端帽、真实比例填充及小号数字；保留充电、低电量模式和未知语义。时钟16pt、网络18pt，与业务行垂直中心对齐。属于公开UIKit自绘近似，不声称使用系统私有状态栏控件。
- 15项定向测试通过（/tmp/island140-focused.log）；新增同壳包含、统一边距/中心线、展开和紧凑、动画父子坐标插值、电池填充/未知值回归。完整./scripts/check.sh退出0（/tmp/island140-check.log）：UI165、Integration967、AppWorkflow138、LiveRuntime225项有通过摘要，实时组205.722秒。NativePresentation的cameraNativeMetalDrawStopAndLayerHandoff仍只有started，无完成摘要，不计为通过。
- ./scripts/build-ios.sh退出0，四项BUILD SUCCEEDED（/tmp/island140-ios.log）；真机Debug签名构建2026110214成功（/tmp/island140-device.log）。25项Agent资源、Widget入口/身份/版本/声明及codesign严格校验退出0（/tmp/island140-agent-resources.log、/tmp/island140-island-resources.log、/tmp/island140-signature.log）。
- 安装到00008150-000579D114C2401C成功，databaseSequenceNumber5580，随后启动成功（/tmp/island140-install.log、/tmp/island140-launch.log）。未操作模拟器界面，未宣称真机动画、视觉、性能功耗验收通过。待用户确认两端状态均在黑色岛身内、跟随裁剪展开/收回、业务位置稳定、电池比例/边距及状态切换。未commit，保留其他工作区修改。


## 2026-11-02 展开岛双行布局与模拟器验收（141）

- 展开时顶部业务/系统状态共同下移6pt，详情起点为紧凑高度加10pt，间隔4pt；底部18pt、正文两侧24pt。主辅图标不再随展开隐藏，计时/loading/频谱继续显示。硬件保护区与横向位置固定，系统状态始终避让完整业务双翼。同一活动的选择/抢占规则未改，不混合其他活动详情。
- 顶部内容独立hosting但仍由同一个UIViewPropertyAnimator控制frame及打断接续；顶部不接收触摸，原详情宿主保留全壳透明命中面。模拟器发现并修复空Group导致缩略图初次不显示，以及顶部数组快照冻结频谱；前者保留透明任务承载，后者SwiftUI直接观察已有频带，不更新Action或壳身revision。overlay固定dark外观。
- 两项定向布局测试通过（/tmp/island141-focused.log）。首轮完整check因新增断言CGFloat?/Double?混用编译失败（/tmp/island141-check.log），显式CGFloat转换后完整check退出0（/tmp/island141-check-final.log）：UI166、Integration967、AppWorkflow138、LiveRuntime225项通过，实时组206.537秒。NativePresentation的cameraNativeMetalDrawStopAndLayerHandoff仍仅started，无完成摘要，不计通过。后续iOS专属视图修正经最终四项构建、原生模拟器复验；未将macOS测试当成其视觉证据。
- 最终./scripts/build-ios.sh退出0，四项BUILD SUCCEEDED（/tmp/island141-ios-acceptance.log），包括25项Agent资源与嵌入Widget身份/版本/声明校验。Swift格式及git diff --check通过。本轮不构建/安装真机包，遵守用户先确认模拟器效果的指示。
- Mac的Xcode27以Device Hub提供模拟器窗口，测试设备9CC7DAF2-4A23-471B-8277-A673D8ECBE7D，iPhone 18 Pro/iOS27。仓库外/tmp/Island141Preview.swift与/tmp/Island141Preview.app链接真实UI.o，bundle dev.mobileharness.island141preview；明确标注测试输入，不采集相机/麦克风、不请求模型，网络/电池与频谱均为注入测试值。该测试壳不加入产品、Action或仓库目录。
- 通过cua界面实际操作并观察：任务短文、长文最大高度布局、图文与纯图片显示；聆听计时、loading、连续输入频谱；箭头收起、上滑收起、两侧状态区域/业务状态重新展开、无详情点击不展开、6轮快速收起/展开后settled。中央硬件黑区的坐标点击未观察到展开，因此不宣称所有物理位置均已验收；使用状态区域点击可展开，硬件区域触摸仍需真机确认。长文布局可见，不将截图当成完整滚动/无障碍验证。
- 最终任务示例由Device Hub截图按钮保存为/Users/devil/Desktop/Screenshot iPhone 18 Pro 11-02-2026 at 2.48.28 PM.png（实际文件名PM前含窄空格），副本/tmp/island141-task.png。最终测试页留在模拟器供用户切换场景确认。未进行真实业务闭环、系统Live Activity交互、性能或功耗测量，未commit。

- 后续用户明确请求安装真机：Debug签名构建2026110215成功（/tmp/island141-device.log），25项Agent资源、Widget身份/版本/声明和codesign --verify --deep --strict分别退出0（/tmp/island141-agent-resources.log、/tmp/island141-island-resources.log、/tmp/island141-signature.log）。安装到00008150-000579D114C2401C成功，databaseSequenceNumber5588（/tmp/island141-install.log）。自动启动被锁屏拒绝，CoreDeviceError10002/Locked（/tmp/island141-launch.log）；只能确认安装，解锁后可手动打开，不声称真机视觉已验收。未修改代码、未commit。
