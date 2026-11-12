# 拍照倒计时与显式打开相机

## 目标与接口

- `Camera.Capture.takePhoto` 接收可选整数 `delaySeconds`（0…30），仅覆盖本次拍摄；省略时使用当前设置，0 表示立即拍摄，不修改持久拍摄偏好。无需先调用 configureCamera。
- openCamera 独立负责打开、恢复、聚焦和等待预览就绪；takePhoto 只在已打开且可用的相机拍摄，保留自动切换 photo 模式，不隐式打开或恢复窗口。
- Photography 教学明确在同轮 open 与 takePhoto 之间插入自然话术；跨 Channel 用 `<wait><openCamera/></wait><wait>看镜头，现在开拍。</wait><takePhoto/>` 确保打开、播报、拍摄按顺序完成，补充倒计时话术示例与解析/调度回归。
- 已知准备与拍摄步骤在同一轮生成多个 Action，如 `<openCamera/><takePhoto delaySeconds="3"/>`。它们沿已有 Camera Channel 顺序执行；跨 Channel 的播报使用 wait。依赖返回身份或实际结果的保存、评价和完成仍等待反馈。
- 解耦后不能依赖原先自动 open 恢复窗口来保证镜头归属：Coordinator 在所有照片模式的入口统一检查 foreground/enabled/visible/lensOwner，并在倒计时后的采集检查重复验证镜头归属，拒绝最小化或被遮挡窗口。
- 不改变 startRecording 的已有自动打开语义，不新增目录或模块。

## 影响文件与职责

- Actions/Camera/CaptureActions.swift：参数声明、纯校验和直接调用，预算移除自动打开所占 60 秒，保留 50 秒倒计时/拍照预算。
- Actions/Support/Contracts/CameraCapabilities.swift、CameraExecutionEndpoint.swift、CameraCoordinator.swift：传递可选倒计时，入口和原有会话验证保持一致；CameraPhotoSession 继续拥有单个可取消、可加入的倒计时/拍照事务。
- Resources/Skills/Photography/Instructions.md：删除分轮准备和拍照自动打开描述，补充已打开、需要打开、倒计时、多 Action 示例。共享输出协议已支持一轮多 Action，无需更改调度器。
- Tests/IntegrationTests/CameraEnhancementTests.swift、GenerationRoundTests.swift、PromptTemplateTests.swift：覆盖参数边界、失败/取消、无隐式打开、真实 Action 声明与 Gateway 的同轮有序执行、预览就绪后才拍照。
- 同步 Actions/Camera、Actions/Support/Contracts、Actions、Resources/Skills、Tests/IntegrationTests 的 README 及 MobileHarness/README.md 中跨模块链路，保留其他工作区修改。

## 验证与状态

实现、教程、技术文档和 11 项专项回归已完成；`./scripts/build-ios.sh` 四个目标及资源校验通过。`./scripts/check.sh` 全量集成阶段仍出现独立机械臂目标值断言失败，单独复跑通过；原生渲染测试未获得完整完成记录，不能宣称全量通过。原生 UI/真实模型/真机未验收；完整证据与剩余验证见[验证记录](../../validation/Photo-Countdown-And-Explicit-Open.md)。
