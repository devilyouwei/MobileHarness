# 眼睛直接跟随视线目标

连续移动时，首页眼睛每次收到新目标都会重新启动 320 ms 位置动画。取消这一层插值，让已经过感知平滑的目标在下一次界面刷新时生效。

修改 [NativeCompanionSurface.swift](../../../MobileHarness/UI/Conversation/NativeCompanionSurface.swift) 的 `CompanionSurfaceView`，在禁用隐式动画的图层事务中直接提交 `gazeLayer.position`。输入仍由相机状态经 `eyeGaze` 传入，继续使用现有坐标限制、位移范围和上游 `FaceGazeTracker` 平滑。表情、眨眼、呼吸和光环各自使用现有动画。接口及跨模块流保持一致，更新 [Conversation 设计](../../../MobileHarness/UI/Conversation/README.md) 的眼睛渲染说明。

在 [Conversation 测试](../../../Tests/UI/Conversation/) 添加原生图层回归测试，通过 [Package.swift](../../../Package.swift) 纳入 `UITests`，覆盖连续视线输入直接提交位置及尺寸变化时的重算，并运行仓库检查。真机验收观察正脸横移时眼睛是否紧跟、静止时是否稳定，以及眨眼和表情是否正常。

代码和设计文档已更新。测试及构建结果见 [项目验证日志](../../validation/Validation-History.md#2026-11-26--眼睛直接跟随视线目标)，真机验收待验证。
