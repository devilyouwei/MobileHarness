# Components — 公共视觉与交互组件

## 职责与关系

组件消费UI自有显示值，拥有原生绘制、交互和有限呈现回执，不持有业务、设备、模型或仓库。Root与功能页面组合组件，Shared提供通用机制；完整组件的模型、状态、布局和平台适配同目录维护，不按View/Model技术类型拆散。

| 组件 | 当前职责 |
| --- | --- |
| [RuntimeLog](RuntimeLog/README.md) | 首页 Channel 摘要和 Action／Task／Agent／Decision 日志面板 |
| [Island](Island/README.md) | App/系统灵动岛的内容、状态、渲染与交互 |
| [Window](Window/README.md) | 通用窗口状态、层级、几何、壳与宿主 |
| VoiceBars.swift | 有界实测频带的原生显示与可测试几何 |
| FadingCaption.swift | 有界字素状态与字幕淡入 |
| LocalVideoPlayer.swift | 已拥有本地文件的原生播放 |
| RetainedFullScreenCover.swift | 保留下层挂载的全屏覆盖 |

Face专属眼睛、光环及Metal资源归[Conversation](../Conversation/README.md)。本目录不拥有功能输入类型或UI模块根生命周期。

## 原生频谱

VoiceBars承载底部聆听频谱，消费32个实测频带，固定UIView／CAGradientLayer／CAShapeLayer拓扑；数值更新提交路径并由Core Animation插值，无逐帧SwiftUI Canvas或timer。非有限值清理、频带截断、失活与Reduce Motion使用固定展示值。尺寸未变不重复布局。

## 字幕

保留最新320个完整Characters，CaptionPresentation维护可测试的稳定／修订边界，CaptionRenderState只保存有界字素与单调出生时间。流式追加延续旧文字淡入，滚动窗口保留仍在显示的文字进度；修订只重置变化后缀，组合字符不会拆开。

一个SwiftUI Text布局，按相邻出生时间合并run并附加TextAttribute；TextRenderer绘制时只改变对应run透明度，新增部分从0.15到1，250ms后完全可见。定稿／Reduce Motion立即不透明；清空、根代际变化、离窗或失活撤销旧动画。无双标签、NSAttributedString覆盖或UIKit字幕备用路径。

Text在TimelineView闭包外由最新输入构造；仅挂载且前台的淡入期间请求不快于60Hz的动画节奏，结束后暂停，不创建线程、逐字Task或定时器。ScrollView在文字提交及实际布局尺寸变化后定位尾部，保留18pt边缘渐变与完整辅助功能值。字号随Dynamic Type更新，文字布局和动画的实际开销仍需采样，不保证比旧实现更快。

## 全屏覆盖

RetainedFullScreenCover 通过 UIKit overFullScreen 保留首页及相机挂载；一个转换标记合并最新呈现期望，不排待呈现队列。关闭后以实际 dismissal 发送一次回调，源销毁不重新呈现。覆盖只负责页面生命周期，不拥有设备或业务清理。

## 本地媒体

LocalVideoPlayer uses AVKit VideoPlayer only for an already-owned local file URL. It owns one AVPlayer, pauses/replaces it on URL change, pauses on scene inactivity, and releases it on disappearance. It never requests camera/microphone/Photos permission or decides file disposition. Playback is manual. AVKit is permitted only for this rendering file by the import boundary checker.

[UI模块](../README.md)

## Web pages

[Web](Web/README.md) owns native WebKit loading, page observation, viewport snapshots and remote/local URL policies. Window supplies its shell; WebPageView mounts the retained renderer. Its native operation receipts and lifetime belong to WebPageContainer, not a SwiftUI page task.
