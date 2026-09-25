# Components · 呈现组件

用途：集中无业务副作用的 SwiftUI 绘制组件。设计目标：通过值输入呈现状态，不启动模型、网关或设备。

- ✅ `VoiceOrb.swift`：真实输入/播放音量驱动的圆环；最多 30 fps，保留加载、蓝色聆听、紫色播放和减弱动态效果。
- ✅ `FadingCaption.swift`：稳定前缀保持，修订后缀淡入，只显示最近 320 字符；保留 VoiceOver 完整文本。
- ❌ 独立通用呈现状态类型：VoiceOrb 暂时沿用 AppLifecycleCoordinator.VoicePhase，后续随状态边界迁移。


维护约定：修改本目录代码、文件或子目录时同步更新此 README；✅ 表示已实现，❌ 表示尚未实现，不用空实现占位。

✅ VoiceOrb overlays a large emoji at 32% of its diameter, with soft purple glow, spring/opacity transitions and no touch interception. Reduced Motion uses fades only. No timer, queue or independent runtime work is created.
