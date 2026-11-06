# Root — UI应用组合与导航

## 职责与上下游

消费UIContainer创建的各功能状态、公共组件及App注入的ApplicationRootProviding/ApplicationSessionProviding窄端口。这里只组合根页面、路由、首页持久挂载与窗口/灵动岛宿主，不创建业务、设备、模型服务，也不持有Agent实现。

| 文件 | 职责 |
| --- | --- |
| ApplicationRootPorts.swift | UI自有的根组合/会话内容端口 |
| ApplicationRootView.swift | 根视图、页面内容与全局组件挂载 |
| PersistentHomeNavigation.swift | 保持Face身份的透明导航容器 |
| NavigationState.swift | UINavigationContainer、路径、导航呈现端口与状态 |
| NavigationContext.swift | 页面/对象/覆盖层语义及页面确认修饰器 |

UIContainer仍在模块根装配导航子容器。功能页面通过导航上下文修饰器确认展示状态，Root组合其实际内容；Root不要求功能页面创建根实例。导航路径变化推进generation并进入transitioning，匹配页面确认后settled；settled只表示页面出现，不代表动画、GPU或业务完成。旧代确认拒绝。相册上下文消费UIAlbumContainer的已有快照，不读取存储。

Face与导航保持稳定兄弟节点；WindowHost属于持久首页内容，位于Face之上、NavigationStack之下，透明区域保留透传。导航页覆盖整个首页和窗口，并阻断其触摸与无障碍。NavigationState仅在路径跨越首页边界时同步通知UIContainer更新首页窗口可见性。IslandHost挂载在常驻导航容器外，使用独立scene覆盖窗口全局显示；设置、记录、相册和详情页均可查看最新状态、展开及收起，导航不改变Island身份、展开偏好或状态栏接管。页面导航不关闭根聆听，不重新授予相机采集。后台停渲染及根停止由UIContainer/对应组件处理，不用页面消失替代设备清理。

[UI模块](../README.md) · [共享机制](../Shared/README.md) · [公共组件](../Components/README.md)

ApplicationRootView根据IslandState.replacesSystemStatusBar绑定系统状态栏隐藏；显示内容、刷新和避让归Island组件。根页面不解释网络/电量事实，不按业务活动类型决定系统状态栏。

系统Live Activity点击仅由系统激活当前scene，Root没有岛链接的导航分发或待处理目的地。后台返回保留现有导航路径、窗口和详情偏好；冷启动走正常首页，不因history/camera/bluetooth旧路径自动打开页面或设备。

Root将IslandState.localFrame底边传给WindowHost的通用topBoundary，WindowHost以全屏视口挂载，最大化外壳贴左右/底边并避开岛身。Root只做组件几何组合，Window和Island互不引用，也不根据Task/Camera状态决定尺寸。

首页和启动占位共用根组合的纵向背景渐变：顶部RGB(0.08, 0.20, 0.32)，底部黑色，延伸到安全区域外。背景不参与命中和无障碍；相机视觉、Face和覆盖组件按原层级叠加，导航页保持自身背景。

ApplicationRootProviding exposes the UI-owned web capability. ApplicationRootView mounts WebPageView for WindowContent.web; this composition adds no model, file or business access to Root.


Root 对 artifact 窗口呈现对应 Web 会话；会话创建前显示等待视图，不创建业务任务。

Settings routes assistantHistory/writerHistory directly to the injected record view, preserving recordContextID and agentRecords/conversation/turn navigation confirmations. Root does not parse task or model data.

artifact窗口将WindowPresentation.subtitle注入WebPageView工具栏；Root只组合通用显示值，不生成作品名或解释Writer状态。
