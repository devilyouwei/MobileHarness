# Window — 通用窗口组件

## 职责与接口

UIContainer持有唯一WindowState；上游提交WindowContent/WindowPresentation和类型化控制请求，宿主注入内容插槽。组件拥有窗口身份、尺寸、层级、聚焦、最小化、呈现过渡和回执，不解释照片、录像、设备租约或Task。依赖Shared请求/状态快照能力；业务清理由请求消费者加入后再更新窗口状态。

WindowState.swift定义模型、边界约束、状态和有界请求；WindowAppearance.swift拥有WindowIcon、图标校验／缩图和原生字体测量；WindowHost.swift定义UIKit宿主、SwiftUI窗口壳及动画。全局最多十二个窗口（含最小化），容量不足明确拒绝；revision/generation拒绝迟到回执，关闭和根失活释放动画等待。UI呈现成功不代表领域操作成功。

## WindowHost 与 WindowChrome

WindowHost只挂载在持久首页层，导航页位于其上并阻断首页触摸／无障碍。WindowState.isHostVisible由UI模块根提供；被导航页覆盖时所有窗口内容与背景均不计可见面积，isCovered为true，避免隐藏相机表面取得镜头权限。导航不关闭窗口、不改窗口身份／模式／正常位置，也不使窗口能力失活；呈现回执表示壳完成布局／过渡，不代表不受导航遮挡。

WindowHost 使用 UIHostingController 承载 SwiftUI 内容，UIViewPropertyAnimator 拥有逐实例可中断框架动画；普通 SwiftUI 页面不创建显示线程。宿主按 WindowState 层级排列，先从 presentation layer 获取当前位置再替换 animator。完成核对 windowID/revision/generation；退出先移除实际表面再回执，离窗和根失活解除等待。透明命中区（含窗口圆角外侧）向下层窗口/Face透传，不安装遮罩。

WindowChrome 只提供标题/控制/内容插槽、有限过渡加载指示、失败文字和声明式决策按钮。最小化不挂载业务内容。柔和色板透明度0.75，高对比度或减少透明度用实色；Reduce Motion 将过渡简化为短淡入淡出。标题双击最大化/还原，卡片单击恢复，标题拖动使用全局坐标且与点击互斥。控制区不参与拖动。

展开标题栏左右各88pt控制槽：左侧为最小化、最大化／还原，右侧为44pt加载空槽和44pt关闭按钮，标题相对窗口中心对齐，加载状态不推动标题。最小化卡片两侧各44pt，左侧显示22pt窗口图标、未指定时留空，右侧关闭；标题两侧各8pt间距并居中。按钮保持44pt触摸范围，只有中间标题区域响应拖动及单／双击；长标题单行截断，不侵占按钮。

Camera surfaces share immutable input but have separate renderer lifetime. The photo surface fits the native aspect and emits black outside the image; background pose uses its existing fill projection. Window chrome remains content-neutral; sizing and visibility come from WindowState.

WindowChrome optionally shows WindowPresentation.activity beneath a minimized title; labels are capped at64 characters by WindowState. The generic shell does not interpret recording state or run a business timer. The title's drag/tap arbitration and separate right close target are retained.

WindowSizing.standard keeps the generic 2/3 safe-area default. WindowSizing.image fits an image aspect plus 52pt title and supplied controls height into safe bounds. Portrait defaults reserve 80pt at the top of the safe area for ordinary expanded overlay content, narrowing proportionally when needed; landscape stays centered. This is initial placement, not a live coupling to island state. Image size changes preserve the normal frame center and re-constrain it; maximized geometry uses the full viewport below the supplied top boundary, with a 4pt gap. WindowState computes visible area after subtracting the union of higher settled window rectangles, including cards. CameraState projects a lens holder from these presentation facts, active Face visibility and a domain handoff gate. ApplicationRootView keeps the Face tree and mounts independent background and window camera renderers. Presentation code never acquires camera resources.

Windows retain their last successfully presented revision. Failed receipts and remounting cannot grant lens authority. The photo image region must intersect the safe area and retain uncovered area to count as a visible camera surface.

[UI模块](../../README.md) · [公共组件](../README.md)


最大化布局与普通/卡片坐标独立：WindowHost全屏挂载，普通窗口继续相对safeArea布局；最大化外壳左右/底部贴视口边界，顶部位于通用topBoundary加4pt，无边界则使用顶部安全区。纯WindowGeometry.maximized将该矩形换算为safe-area相对坐标，WindowState.maximizedFrame同时服务渲染、遮挡和镜头可见性。Root传入Island实际本地占用底边；Window不引用Island或业务类型。

最大化外壳无圆角和边线，黑色背景填满至屏幕底边；标题/内容横向与底部控件保留必要安全内边距。UIHostingController不再次自动施加safeArea，避免重复缩进。顶部占用变化重新计算最大化frame，并从当前视觉frame接续既有动画；normal/card/restoreMode保持独立，最小化后恢复使用最新最大化布局。普通拖动仍直接跟手，不逐帧调用Action。

WindowContent.web allows multiple independent windows. The shared limit across Web, artifacts and Camera is twelve windows. Each Web window renders its own UI.WebPageView; injected Actions lifecycle joins outstanding page/editor operations on minimize or close. WindowState does not inspect URLs, workspace revisions or model requests.

## 最小化宽度与图标

卡片按标题实际字体测量，宽度为文字宽度加两侧槽与间距，范围128…320pt，并以安全视口宽度减32pt为上限。超过宽度的标题单行尾部省略，不压缩图标和44pt关闭命中区。初始卡片距右边16pt；旋转或Dynamic Type字号变化重算卡片宽度，保留中心后约束位置，普通窗口位置／尺寸及restoreMode独立。高度48pt，activity仍在第二行单行截断，不驱动卡片变宽。

WindowHost监听原生字体类别，使用subheadline实际字号提交layout；卡片标题以同字号、semibold渲染和测量。测量只在创建／布局变化发生，拖动不逐帧测量标题。标题区域保留单击恢复和拖动，左侧图标为装饰，不接管关闭按钮事件；无障碍仍读取标题。

WindowState.present的可选icon参数接收WindowIcon.system(name:)、emoji单个组合字符或image(Data)，首次创建时校验，随后与窗口身份一起保留；单实例复用保留原图标。业务调用者决定图标，组件不根据content猜测。自定义图片输入最多1MiB、宽高各不超过4096，接纳时解码首帧并按方向缩为最长边96像素PNG，保留透明度和比例；渲染到22pt等比框。非法符号、emoji或图片抛出invalidIcon，不创建窗口，不以空白伪装成功。图片只来自显式字节，不读磁盘／网络，关闭窗口或根停止释放状态持有的图标，渲染缓存随视图销毁。图标数据不进入状态快照。


artifact 内容为多实例作品窗口，页面由 Web sessions 按 windowID 隔离。创作任务由 Writer 根持有；最小化/关闭仅改变页面呈现，不结束作品任务。

ui.windows投影同一WindowState的全部窗口，包含Writer的artifact窗口；来源Agent不参与过滤。Skill只选择是否观察此公开State，不能改变窗口所有权或实例。页面正文/截图通过对应Web会话的显式业务能力获取，窗口摘要不表示看到了页面像素。

WindowPresentation公开通用subtitle，setPresentation只更新标题/副标题和最小化卡片测量宽度，不聚焦、恢复、导航或改变正常frame；可在Scene隐藏时缓存。ui.windows投影受限subtitle供所有观察者读取。present新建时可接收宿主预留windowID，拒绝重复身份；单实例复用仍返回已有身份，首次呈现回执仍受revision/generation约束。

窗口标题与内容工具栏副标题分工独立；Root将artifact窗口的subtitle传入通用WebPageView，Window/Web均不解释Writer步骤或Task。

WindowState owns monotonically allocated window_N references for external Action/State use. Internal UUIDs continue to fence native presentation, asynchronous inputs and animations. reference(for:) and resolve(reference:) are the single mapping; closed/missing references and UUID strings cannot address a live window. All creators share this namespace.
