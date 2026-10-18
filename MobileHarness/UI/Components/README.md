# Components — 原生呈现组件

## 职责与上下游

消费 Conversation／Camera 提供的 UI 值，输出原生图层和带身份的动画回执。不拥有设备、模型、业务队列或 IoC。UIKit 管理视图／图层挂载，Metal 所有者管理各自显示线程及真实 GPU 完成。

## 文件归类

| 文件 | 职责 |
| --- | --- |
| NativeCompanionSurface.swift | 眼睛、视线、眨眼、呼吸及光环挂载，启动眼睛包装 |
| EyeGeometry.swift | 可跨平台验证的连续眼睛曲线 |
| ListeningMotion.swift | 归一化光源和单调时间运动状态 |
| MetalHaloRenderer.swift / ListeningHalo.metal | 光环管线、显示线程和像素光效 |
| VoiceBars.swift | 顶部／底部频谱原生图层及固定拓扑几何 |
| FadingCaption.swift | 常驻双 UILabel 字幕及增量透明度动画 |
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

✅ 同步提交最新完整文字，保留最新320个完整 Characters，并以 UTF-16 边界区分稳定／新增范围。两个 UILabel 使用同一完整字符串及排版，新增范围以250ms opacity 动画淡入；模型层透明度始终为1。定稿／Reduce Motion 直接显示，取消或替换不留下低透明度文本。

UIScrollView 仅在文字／尺寸变化时定位尾部，保留18pt边缘渐变及完整辅助功能值。不创建逐字 timer 或异步文字副本，离窗移除动画。文字测量和图层提交仍受主线程预算约束。

## 全屏覆盖

RetainedFullScreenCover 通过 UIKit overFullScreen 保留首页及相机挂载；一个转换标记合并最新呈现期望，不排待呈现队列。关闭后以实际 dismissal 发送一次回调，源销毁不重新呈现。覆盖只负责页面生命周期，不拥有设备或业务清理。

❌ 频谱缓存的实际收益、全屏光效功耗、原生交互和持续帧率仍须分别测量／验收，不以技术选型代替结论。

[UI 根](../README.md) · [验证记录](../../../docs/validation/PlatformKit-Containers.md)
