# Window — 通用窗口组件

## 职责与接口

UIContainer持有唯一WindowState；上游提交WindowContent/WindowPresentation和类型化控制请求，宿主注入内容插槽。组件拥有窗口身份、尺寸、层级、聚焦、最小化、呈现过渡和回执，不解释照片、录像、设备租约或Task。依赖Shared请求/状态快照能力；业务清理由请求消费者加入后再更新窗口状态。

WindowState.swift定义模型、边界约束、状态和有界请求；WindowHost.swift定义UIKit宿主、SwiftUI窗口壳及动画。最多4窗口（含最小化），容量不足明确拒绝；revision/generation拒绝迟到回执，关闭和根失活释放动画等待。UI呈现成功不代表领域操作成功。

## WindowHost 与 WindowChrome

WindowHost 使用 UIHostingController 承载 SwiftUI 内容，UIViewPropertyAnimator 拥有逐实例可中断框架动画；普通 SwiftUI 页面不创建显示线程。宿主按 WindowState 层级排列，先从 presentation layer 获取当前位置再替换 animator。完成核对 windowID/revision/generation；退出先移除实际表面再回执，离窗和根失活解除等待。透明命中区（含窗口圆角外侧）向下层窗口/Face透传，不安装遮罩。

WindowChrome 只提供标题/控制/内容插槽、有限过渡加载指示、失败文字和声明式决策按钮。最小化不挂载业务内容。柔和色板透明度0.75，高对比度或减少透明度用实色；Reduce Motion 将过渡简化为短淡入淡出。标题双击最大化/还原，卡片单击恢复，标题拖动使用全局坐标且与点击互斥。控制区不参与拖动。

展开标题栏左右各88pt控制槽：左侧为最小化、最大化／还原，右侧为44pt加载空槽和44pt关闭按钮，标题相对窗口中心对齐，加载状态不推动标题。最小化卡片两侧各44pt，左侧留空、右侧关闭，标题同样居中。按钮保持44pt触摸范围，只有中间标题区域响应拖动及单／双击；长标题单行截断，不侵占按钮。

Camera surfaces share immutable input but have separate renderer lifetime. The photo surface fits the native aspect and emits black outside the image; background pose uses its existing fill projection. Window chrome remains content-neutral; sizing and visibility come from WindowState.

WindowChrome optionally shows WindowPresentation.activity beneath a minimized title; labels are capped at64 characters by WindowState. The generic shell does not interpret recording state or run a business timer. The title's drag/tap arbitration and separate right close target are retained.

WindowSizing.standard keeps the generic 2/3 safe-area default. WindowSizing.image fits an image aspect plus 52pt title and supplied controls height into safe bounds. Portrait defaults reserve 80pt at the top of the safe area for ordinary expanded overlay content, narrowing proportionally when needed; landscape stays centered. This is initial placement, not a live coupling to island state. Image size changes preserve the normal frame center and re-constrain it; maximized geometry uses the full viewport below the supplied top boundary, with a 4pt gap. WindowState computes visible area after subtracting the union of higher settled window rectangles, including cards. CameraState projects a lens holder from these presentation facts, active Face visibility and a domain handoff gate. ApplicationRootView keeps the Face tree and mounts independent background and window camera renderers. Presentation code never acquires camera resources.

Windows retain their last successfully presented revision. Failed receipts and remounting cannot grant lens authority. The photo image region must intersect the safe area and retain uncovered area to count as a visible camera surface.

[UI模块](../../README.md) · [公共组件](../README.md)


最大化布局与普通/卡片坐标独立：WindowHost全屏挂载，普通窗口继续相对safeArea布局；最大化外壳左右/底部贴视口边界，顶部位于通用topBoundary加4pt，无边界则使用顶部安全区。纯WindowGeometry.maximized将该矩形换算为safe-area相对坐标，WindowState.maximizedFrame同时服务渲染、遮挡和镜头可见性。Root传入Island实际本地占用底边；Window不引用Island或业务类型。

最大化外壳无圆角和边线，黑色背景填满至屏幕底边；标题/内容横向与底部控件保留必要安全内边距。UIHostingController不再次自动施加safeArea，避免重复缩进。顶部占用变化重新计算最大化frame，并从当前视觉frame接续既有动画；normal/card/restoreMode保持独立，最小化后恢复使用最新最大化布局。普通拖动仍直接跟手，不逐帧调用Action。
