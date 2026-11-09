# 相机设置与卸载预览的成功回执

Camera.Capture.configure 和 unloadPreviewImage 返回 Void。CameraModule 通过既有 handler 生成结构化完成回执，成功本身不要求 Assistant 再推理。configure 应用默认参数、原生配置及状态发布。unload 验证调用方与缓存身份，再移除当前会话的显式选择。CameraControlCapability、CameraExecutionEndpoint 和 CameraCoordinator 的卸载路径只完成选择变更。实际硬件设置及预览选择由 State 读取，loadPreviewImage 返回观察以支持下一轮图像输入。

## 2026-11-09 验证

- 两项相机回归通过真实模块绑定验证结构化完成、参数转发和异常传播，36 个共享 ReACT 用例通过。首轮编译发现一处旧测试夹具名称，已修正并复跑。
- `scripts/check.sh` 退出 0，主集成 1107 项和 LiveRuntimeTests 228 项通过。原生相机呈现用例在全量和单独复测日志里都只有开始记录，未取得完成证据。
- `scripts/build-ios.sh` 退出 0，四个 iOS 模拟器方案、34 项 Agent/Skill 资源与 Live Activity 打包校验通过。
- 当前工作区签名构建 `0.1.0 (2026110904)` 通过严格签名和资源校验，已原位安装到 iPhone 17 Pro。安装回执序号 6424，设备清单确认版本。此项记录覆盖构建和安装。
