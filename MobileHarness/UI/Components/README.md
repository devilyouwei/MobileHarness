# Components — 原生呈现组件

加载动画改为两个独立缩放图层按1.2秒周期左右一大一小交换，恒定明暗和位置；减少动态效果时保留静态大小眼。退出／失活清理动画及缩放，不新增线程或逐帧 Task。

## 职责与上下游

消费 Conversation／Camera 提供的 UI 值，输出原生图层和带身份的动画回执。不拥有设备、模型、业务队列或 IoC。UIKit 管理视图／图层挂载，Metal 所有者管理各自显示线程及真实 GPU 完成。

## 文件归类

| 文件 | 职责 |
| --- | --- |
| NativeCompanionSurface.swift | 眼睛、视线、眨眼、呼吸及光环挂载，启动眼睛包装 |
| EyeGeometry.swift | 可跨平台验证的连续眼睛曲线 |
| ListeningMotion.swift | 归一化光源、单调时间运动状态及光环接纳／去重 |
| MetalHaloRenderer.swift / ListeningHalo.metal | 光环管线、显示线程和像素光效 |
| VoiceBars.swift | 顶部／底部频谱原生图层及固定拓扑几何 |
| FadingCaption.swift | 单Text字幕、run出生时间与TextRenderer透明度绘制 |
| RetainedFullScreenCover.swift | 保留下层挂载的原生全屏覆盖 |

启动眼睛包装与原生眼睛同属 NativeCompanionSurface，频谱及其可测试几何归 VoiceBars。组件保留真实动画／GPU 回执，运行路径不含临时性能对比程序。

## 眼睛与光源

全部表情共用八段顺时针三次曲线及对应控制点，形状插值保留连续接点；不交换表情图片。眼宽、间距、眼高分别按脸宽的21%、19%、25%布局。视线使用归一化输入及有界位移。

原生路径／shadowPath／变换从 presentation 当前值开始插值，持续基态和有限表演身份分开。常规变化650ms，唤醒180ms，闭合460ms，视线320ms；Reduce Motion 简化重复动画。眨眼和呼吸为独立图层动画，唤醒后延迟启动，休眠／失活／离窗时停止。完成回调不能将替换或不可用当作成功。

ListeningLightOrigin 接受有限归一化坐标并逐轴回退／截断；ListeningMotion 仅在新 generation 锁定光源和起点。眼睛、光环使用同一时刻提交，稳定期改变光源不会移动正在运行的波。装饰光有独立身份；移除装饰覆盖不会重播聆听唤醒。

## Metal 光环

管线离 MainActor 准备；一个全屏三角形绘制扩散前沿、尾部及边缘光，不叠加全屏 SwiftUI 模糊。入场初始透明度至少0.85，进入／退出透明度各320ms，扩散约720ms并在约1.05秒稳定。Reduce Motion 保留静态场和简化过渡。

渲染器拥有独立线程和 CAMetalDisplayLink；一个最新快照、最多一个合并唤醒、最多三个 GPU 在途命令。满载跳过显示机会，不累计帧。过渡请求屏幕支持的刷新率，稳定流动请求60Hz，无需更新时暂停；请求不保证实际帧率。停止关闭接纳，在线程上注销显示链并等待真实 GPU 完成，不阻塞主线程。

光环线程句柄与退出标记统一由锁保护；Thread 句柄本身不具备 Sendable，控制结构仅以锁保护的引用发布／唤醒方式跨域，采用与相机相同的受限 unchecked Sendable 契约；退出使用可明确停止的 RunLoop；等待真实 GPU 完成后归还全部槽位，并提供非主线程完成屏障。频谱固定颜色／线宽／布局仅在对应配置变化时提交，数值变化只更新路径。

管线／GPU 失败通过注入回调报告；眼睛仍保持自己的动画完成语义。布局仅在 frame、scale 或 drawableSize 变化时更新，禁用隐式事务。

## 原生频谱

岛布局由Conversation仅在圆弧切点之间挂载本组件，外层硬遮罩裁掉端点辉光，水平缩放适配紧凑／展开直线段，顶部锚点的有限纵向动画形成向下冒出；组件仍生成32根竖直柱，不感知蓝牙或任务策略。

VoiceBars.swift的回复频谱改为32根同一水平基线向下的直柱，覆盖传入宽度的两端，无弧角、曲线rim或侧向法线。几何及图层不包含弧形边沿；底部麦克风频谱保持原方向。NativeSpectrumView提供停止图层动画接口供岛组件统一清理，失活不继续路径动画；仍只消费实测频带。岛身／对称扩展及同步揭示由[Conversation](../Conversation/README.md)拥有。

上下频谱只消费32个实测频带，不计算 FFT、不生成模拟音频。常驻 UIView、CAGradientLayer、CAShapeLayer 持有固定拓扑；数值更新提交路径，由 CABasicAnimation 插值，无逐帧 SwiftUI Canvas 或 timer。

保留上下位置、渐变和有界阴影；非有限值清理、频带截断、失活和 Reduce Motion 使用固定展示值。相同输入不重画，尺寸未变不重复布局。原生图层方式不代表所有工作均在 GPU，实际合成／功耗另行测量。

## 字幕

保留最新320个完整Characters，CaptionPresentation维护可测试的稳定／修订边界，CaptionRenderState只保存有界字素与单调出生时间。流式追加延续旧文字淡入，滚动窗口保留仍在显示的文字进度；修订只重置变化后缀，组合字符不会拆开。

一个SwiftUI Text布局，按相邻出生时间合并run并附加TextAttribute；TextRenderer绘制时只改变对应run透明度，新增部分从0.15到1，250ms后完全可见。定稿／Reduce Motion立即不透明；清空、根代际变化、离窗或失活撤销旧动画。无双标签、NSAttributedString覆盖或UIKit字幕备用路径。

Text在TimelineView闭包外由最新输入构造；仅挂载且前台的淡入期间请求不快于60Hz的动画节奏，结束后暂停，不创建线程、逐字Task或定时器。ScrollView在文字提交及实际布局尺寸变化后定位尾部，保留18pt边缘渐变与完整辅助功能值。字号随Dynamic Type更新，文字布局和动画的实际开销仍需采样，不保证比旧实现更快。

## 全屏覆盖

RetainedFullScreenCover 通过 UIKit overFullScreen 保留首页及相机挂载；一个转换标记合并最新呈现期望，不排待呈现队列。关闭后以实际 dismissal 发送一次回调，源销毁不重新呈现。覆盖只负责页面生命周期，不拥有设备或业务清理。


[UI 根](../README.md) · [验证记录](../../../docs/validation/PlatformKit-Containers.md)

光环故障对当前实例锁存并停止接纳，仅报告首次故障；相同运动／尺寸／可见性不唤醒线程，刷新率仅变化时提交。失败只停止光环，眼睛仍独立回执；新渲染实例重新接纳。保持GPU完成回收与现有帧率。


loading双眼采用同拓扑睁眼轮廓，独立父图层由 Core Animation 按1.2秒周期缩放，左右在1.12与0.68之间反向交替；位置与明暗保持。缩放与眼形／镜像／视线变换分离，不增加线程、Canvas或逐帧Task；减少动态效果时保留静态大小眼，终态／离窗／后台／销毁移除循环并恢复缩放，不依赖Metal光环或聆听启用。

## WindowHost 与 WindowChrome

WindowHost 使用 UIHostingController 承载 SwiftUI 内容，UIViewPropertyAnimator 拥有逐实例可中断框架动画；普通 SwiftUI 页面不创建显示线程。宿主按 WindowState 层级排列，先从 presentation layer 获取当前位置再替换 animator。完成核对 windowID/revision/generation；退出先移除实际表面再回执，离窗和根失活解除等待。透明命中区（含窗口圆角外侧）向下层窗口/Face透传，不安装遮罩。

WindowChrome 只提供标题/控制/内容插槽、有限过渡加载指示、失败文字和声明式决策按钮。最小化不挂载业务内容。柔和色板透明度0.75，高对比度或减少透明度用实色；Reduce Motion 将过渡简化为短淡入淡出。标题双击最大化/还原，卡片单击恢复，标题拖动使用全局坐标且与点击互斥。控制区不参与拖动。

展开标题栏左右各88pt控制槽：左侧为最小化、最大化／还原，右侧为44pt加载空槽和44pt关闭按钮，标题相对窗口中心对齐，加载状态不推动标题。最小化卡片两侧各44pt，左侧留空、右侧关闭，标题同样居中。按钮保持44pt触摸范围，只有中间标题区域响应拖动及单／双击；长标题单行截断，不侵占按钮。

Camera surfaces share immutable input but have separate renderer lifetime. The photo surface fits the native aspect and emits black outside the image; background pose uses its existing fill projection. Window chrome remains content-neutral; sizing and visibility come from WindowState.
