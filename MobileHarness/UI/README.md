# UI — 呈现与人机交互

## 职责与边界

UI是零项目模块依赖的基础模块。只接收UI自有值和注入的操作接口，拥有展示状态、原生渲染及交互回执，不拥有设备、模型、仓库或业务策略；不导入Actions、Agents、Gateway、PlatformKit、Storage或FactoryKit。

App缓存唯一UIContainer并管理根生命周期。Actions通过呈现端口提交内容；业务消费者订阅UI子容器的类型化请求，页面不持有Agent身份。UI不选择异常是否提示，也不把动画完成当作拍摄或设备清理成功。

Interaction routing follows the [overall design rule](../README.md#two-ui-interaction-paths): presentation-only changes stay in UI; business requests go through the responsible Agent, Gateway and Actions. UI handlers submit intent and do not implement business queries, persistence, device operations or domain lifecycle coordination.

## 目录与内部关系

| 位置 | 当前责任 |
| --- | --- |
| UIContainer.swift | 唯一模块根、UIConfiguration、子能力构造和根生命周期 |
| [Root](Root/README.md) | 根视图、组合端口、持久Face导航和页面上下文 |
| UIFailure.swift / UIStateSnapshot.swift | 模块统一失败、错误回调及整体State契约 |
| [Shared](Shared/README.md) | 跨功能请求/回执、呈现接纳与代际凭证 |
| [Components](Components/README.md) | 通用字幕、频谱、播放器、覆盖层，以及完整Island/Window组件 |
| [Conversation](Conversation/README.md) | Face、会话、执行记录、眼睛与Metal光环 |
| [Camera](Camera/README.md) | 相机视频、骨架、照片与视频呈现 |
| [Settings](Settings/README.md) | 设置、模型资源、蓝牙、历史和相册呈现 |
| [Diagnostics](Diagnostics/README.md) | 真实诊断页面与输入/结果呈现 |

Root组合功能视图与公共组件，功能拥有自身状态和输入类型；两者共用Shared机制。组件内部模型/状态/布局同目录维护。Shared不反向引用具体功能。根目录保留模块入口与整体契约；Shared保留可复用机制，具体能力跟随所属目录。Root目录是根页面组合，不是模块API根。运行时所有权仍由实际Container/State决定；模块继续是一个UI target。

## 直接接口与数据流

根构造时创建十二个稳定子能力，不在首次回复或页面切换时补建：

| 子能力 | 状态owner |
| --- | --- |
| home | Conversation/UIHomeContainer |
| camera | Camera/UICameraContainer |
| settings / modelResources / history / album / devices | Settings内对应子容器 |
| navigation | Root/UINavigationContainer |
| diagnostics | Diagnostics/UIDiagnosticsContainer |
| windows | Components/Window/WindowState |
| web | Components/Web/WebPageContainer |
| island | Components/Island/IslandState |

页面→子容器类型化请求→注入消费者→业务执行→UI呈现值→状态→原生绘制。请求接纳与完成独立，有界容量、取消和迟到回执规则见Shared；公开类型名称保持稳定。home聆听控制使用独立单槽源，普通请求最多64个在途。

UIContainer.stateSnapshot只返回自身生命周期事实及十二子能力的路径索引；各owner只投影已有事实，不采样设备、不递归读取其他owner。密钥、本地URL、草稿、字幕和媒体字节不进入公开快照；业务操作失败与UI呈现健康分别表达。

Writer 记录使用 UI 自有 WriterRecordsControlling 和分页 DTO 接收明确的下一游标；Settings 页面拥有已加载快照与导航返回保留，业务提供方拥有记录查询。详见 [Writer 记录](Settings/README.md#writer-记录与作品)。

## 生命周期与完成

构造/start不请求权限、不启动设备或模型。invalidate使旧实时凭证失效、关闭实时呈现并解除动画等待；stop幂等取消并加入UI自有工作，清理资源和回调，旧根不能重启。会话/轮次、设置revision、媒体generation和领域序号独立于根代际。

setSceneActive与完整invalidate/setForeground分开：后台关闭窗口接纳、相机与App内岛渲染，保留正在运行会话的呈现token、已接纳输入和事实。同一Island活动继续更新系统Live Activity，返回前台挂载当前内容。UI不决定后台音频或设备的业务生命周期。

Face和首页WindowHost原生树与导航保持身份；层级为首页→Window→导航页→全局本地Island。UIContainer接收NavigationState的首页边界变化，仅更新首页窗口宿主可见性。Island使用根拥有的单一覆盖窗口，所有页面持续更新同一活动和展开偏好；导航不拆卸Island、不改变状态栏接管，页面打开/返回不停止根聆听。窗口内容以插槽挂载，最小化停止隐藏内容绘制，业务设备暂停/关闭由消费者执行。相机后台关闭开启意图，回前台需要明确重开；UI不擅自恢复采集。

原生渲染器拥有自己的显示链与GPU完成屏障；接纳不代表上屏，页面settled不代表动画完成。UIFailure保留原始错误和清理失败，有限动画使用身份/版本回执，旧代拒绝不会成为逐帧故障广播。

## 关键组件

[Window](Components/Window/README.md)封装最多十二个窗口、层级、几何、最小化和动画；[Island](Components/Island/README.md)封装同源App/系统活动、内容驱动展开、详情与实时状态独立排序、图片资源、计时和动效。调用方提交内容，布局与交互由组件拥有。系统外壳、展开时机及可用动画仍受iOS控制。

[Conversation](Conversation/README.md)拥有眼睛、光环和会话投影；字幕/频谱接收有界文本及实测频带，不制造音频数据。性能、功耗和真实触控体验通过真机验收，不由目录组织或动画技术推断。

[总体设计](../README.md)

灵动岛默认系统状态通过根构造的只读UI值端口注入，本地组件拥有刷新/布局及实际挂载标志；Root绑定系统状态栏隐藏和恢复。系统状态不进入Action内容接口，UI不创建平台采样器。见[Island](Components/Island/README.md#默认系统状态条)。

CameraPresenting exposes a bounded, cancellable fresh-frame geometry receipt for capture startup. UICameraContainer resolves it from admitted camera frames or lifecycle failure, without broadcasting frame traffic as Facts; Actions awaits the receipt before requesting device capture. See [Camera](Camera/README.md) for admission, deadlines and cleanup.

[Web](Components/Web/README.md) is the twelfth stable child capability, owned by UIContainer. It creates WKWebView on demand and exposes load/observe/snapshot/navigation receipts; Window.web supplies a single presentation slot. App injects this capability directly into ApplicationRootProviding. UI imports WebKit only in the owning component and never imports model, business or storage modules.

Window接受调用方提供的系统图标、emoji或图片字节；组件拥有校验、规范化和最小化卡片的有界自适应布局，UI不读取业务文件／URL。详细尺寸与资源边界见[Window](Components/Window/README.md)。

Island 是多来源 App 状态的通用呈现中心：业务拥有事实和内容，组件拥有语义优先级顺序、详情/实时状态两路仲裁、布局、可中断动画和展开偏好。生产者使用同一内容接口，UI 不识别具体 Agent；Writer 自己发布任务内容不增加 UI 对 Agents 的依赖。

ui.web 按 windowID 提供网页与作品的被动会话摘要；ui.windows跨创建者提供全部窗口。两者保持各自状态所有权，公开读取不创建页面或执行脚本。

Conversation字幕槽只执行各自业务拥有者显式提交的更新／清理，不因回复结束或聆听开关丢弃文字。根失效通过UIHomeContainer显式清理两个槽；具体呈现与所有权边界见 [Conversation](Conversation/README.md)。

Web 的连续本地预览在受控读取根内复用原生表面和文档，以隔离宿主 DOM 更新保持滚动、缩放及触控；完整本地导航提供视口恢复和过渡覆盖。调用方拥有快照文件与根授权，UI 不感知作品任务。具体更新、取消和失败契约见 [Web](Components/Web/README.md)。

Writer记录页消费Writer投影的累计执行时长、当前执行起点及Chat请求时间证据，展示紧凑元信息、最新状态和可展开源码；UI不统计数据库或采集模型计时。详情布局与未知耗时规则见[Settings](Settings/README.md)。

Window提供可更新标题/副标题及宿主预留身份，Root把副标题组合到Web内容栏。业务名称、重名区分和步骤属于调用方；UI只缓存、测量、截断和呈现，场景失活不清除这些事实。

Writer请求行编号徽章默认灰色，仅失败为红色，并呈现调用方给定操作标题；状态中文标签与时间并排。UI不访问工具参数或请求模型命名，完整规则见[Settings](Settings/README.md)。

记录入口和列表使用My Assistant/My Writer命名；Settings目录内共用记录行几何与紧凑日期显示，不增加存储读取或把会话创建时间推断成活跃时间。默认historyTitle为My Assistant，仍支持宿主显式覆盖。

Conversation-history image presentation distinguishes missing or cleared request-log images from read/decode failures. The workflow supplies the outcome through the UI-owned HistoryImageAvailabilityError contract; UI does not access the Camera cache or select model images.

Camera gallery renders supplied session catalog metadata and scoped read results, with bounded stack thumbnails and zoomable current/adjacent pages. CameraState owns presentation only; closing/eviction and model selection belong to Actions. Shutter controls overlay the live image with a translucent gradient.

Settings历史详情支持清空单条请求日志，历史列表支持清空Assistant/Writer共享全库。确认后 Prompts 和 Generation Meta 显示“已清空”，回复、Action 和工具结果等业务区块保留。新历史图片来自完整模型请求中的Base64，与Camera缓存寿命独立。

首次云端配置由 Root 组合 Settings 的 WelcomeProviderView：恢复完成后按实际 Provider 列表判断展示；表单通过既有 SettingsControlling/SettingsOperating 提交，业务持久化仍由外部 Actions 拥有。成功后进入模型选择，UI 不推定服务支持的模型，也不访问钥匙串或网络。
