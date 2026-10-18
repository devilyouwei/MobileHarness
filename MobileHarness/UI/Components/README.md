# Components — 原生呈现组件

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

✅ 启动眼睛包装与原生眼睛同属 NativeCompanionSurface，频谱及其可测试几何归 VoiceBars。组件保留真实动画／GPU 回执，运行路径不含临时性能对比程序。

## 眼睛与光源

✅ 全部表情共用八段顺时针三次曲线及对应控制点，形状插值保留连续接点；不交换表情图片。眼宽、间距、眼高分别按脸宽的21%、19%、25%布局。视线使用归一化输入及有界位移。

原生路径／shadowPath／变换从 presentation 当前值开始插值，持续基态和有限表演身份分开。常规变化650ms，唤醒180ms，闭合460ms，视线320ms；Reduce Motion 简化重复动画。眨眼和呼吸为独立图层动画，唤醒后延迟启动，休眠／失活／离窗时停止。完成回调不能将替换或不可用当作成功。

ListeningLightOrigin 接受有限归一化坐标并逐轴回退／截断；ListeningMotion 仅在新 generation 锁定光源和起点。眼睛、光环使用同一时刻提交，稳定期改变光源不会移动正在运行的波。装饰光有独立身份；移除装饰覆盖不会重播聆听唤醒。

## Metal 光环

✅ 管线离 MainActor 准备；一个全屏三角形绘制扩散前沿、尾部及边缘光，不叠加全屏 SwiftUI 模糊。入场初始透明度至少0.85，进入／退出透明度各320ms，扩散约720ms并在约1.05秒稳定。Reduce Motion 保留静态场和简化过渡。

渲染器拥有独立线程和 CAMetalDisplayLink；一个最新快照、最多一个合并唤醒、最多三个 GPU 在途命令。满载跳过显示机会，不累计帧。过渡请求屏幕支持的刷新率，稳定流动请求60Hz，无需更新时暂停；请求不保证实际帧率。停止关闭接纳，在线程上注销显示链并等待真实 GPU 完成，不阻塞主线程。

✅ 光环线程句柄与退出标记统一由锁保护；Thread 句柄本身不具备 Sendable，控制结构仅以锁保护的引用发布／唤醒方式跨域，采用与相机相同的受限 unchecked Sendable 契约；退出使用可明确停止的 RunLoop；等待真实 GPU 完成后归还全部槽位，并提供非主线程完成屏障。频谱固定颜色／线宽／布局仅在对应配置变化时提交，数值变化只更新路径。

管线／GPU 失败通过注入回调报告；眼睛仍保持自己的动画完成语义。布局仅在 frame、scale 或 drawableSize 变化时更新，禁用隐式事务。

## 原生频谱

✅ 上下频谱只消费32个实测频带，不计算 FFT、不生成模拟音频。常驻 UIView、CAGradientLayer、CAShapeLayer 持有固定拓扑；数值更新提交路径，由 CABasicAnimation 插值，无逐帧 SwiftUI Canvas 或 timer。

保留上下位置、渐变和有界阴影；非有限值清理、频带截断、失活和 Reduce Motion 使用固定展示值。相同输入不重画，尺寸未变不重复布局。原生图层方式不代表所有工作均在 GPU，实际合成／功耗另行测量。

## 字幕

✅ 保留最新320个完整Characters，CaptionPresentation维护可测试的稳定／修订边界，CaptionRenderState只保存有界字素与单调出生时间。流式追加延续旧文字淡入，滚动窗口保留仍在显示的文字进度；修订只重置变化后缀，组合字符不会拆开。

一个SwiftUI Text布局，按相邻出生时间合并run并附加TextAttribute；TextRenderer绘制时只改变对应run透明度，新增部分从0.15到1，250ms后完全可见。定稿／Reduce Motion立即不透明；清空、根代际变化、离窗或失活撤销旧动画。无双标签、NSAttributedString覆盖或UIKit字幕备用路径。

Text在TimelineView闭包外由最新输入构造；仅挂载且前台的淡入期间请求不快于60Hz的动画节奏，结束后暂停，不创建线程、逐字Task或定时器。ScrollView在文字提交及实际布局尺寸变化后定位尾部，保留18pt边缘渐变与完整辅助功能值。字号随Dynamic Type更新，文字布局和动画的实际开销仍需采样，不保证比旧实现更快。

## 全屏覆盖

RetainedFullScreenCover 通过 UIKit overFullScreen 保留首页及相机挂载；一个转换标记合并最新呈现期望，不排待呈现队列。关闭后以实际 dismissal 发送一次回调，源销毁不重新呈现。覆盖只负责页面生命周期，不拥有设备或业务清理。

❌ 频谱缓存的实际收益、全屏光效功耗、原生交互和持续帧率仍须分别测量／验收，不以技术选型代替结论。

[UI 根](../README.md) · [验证记录](../../../docs/validation/PlatformKit-Containers.md)

✅ 光环故障对当前实例锁存并停止接纳，仅报告首次故障；相同运动／尺寸／可见性不唤醒线程，刷新率仅变化时提交。失败只停止光环，眼睛仍独立回执；新渲染实例重新接纳。保持GPU完成回收与现有帧率。
