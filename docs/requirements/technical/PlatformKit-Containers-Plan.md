# PlatformKit IoC、App 生命周期与设备 Signal 接入

状态：✅ 容器、接口迁移与专项测试已实现；❌ 完整并行回归未通过，Simulator 外部依赖受阻，基础相机真机行为已有用户反馈，长时间模型/性能验收仍未完成。基线 a460d99c，工作区在开始前干净，无需空提交。不新增目录或编译目标。

## 交付

AppStorage 注册 PlatformContainer 和 Audio/Vision/Connectivity 子能力；FactoryKit 只存在 App 注册层。基础库保持零项目依赖；Gateway 允许单向依赖 PlatformKit，负责原生设备输入的适配、Signal 封装、验证和传输。Agents 保留决策与会话策略，App 按依赖图管理根生命周期。

首页视频由 Actions CameraCoordinator 独立订阅原生最新帧并提交 UI；Pose Tool 只更新带来源帧、受时限约束的骨架，姿态失败不清除仍新鲜的视频。只读附件不序列化，展示使用有界最新状态与 750 ms 新鲜度。现有外部业务意图已纳入统一 Gateway 封装；完整原生验收仍单独记录。

## 验证

根隔离、无效果构造、失败回滚/取消/重复停止、原生互斥、代际与订阅关闭、PCM 有序/溢出、图像替换、同帧与过期释放。运行 scripts/check.sh 和完整 Xcode 下 scripts/build-ios.sh，区分自动化、编译及真实模型/原生 UI/设备验收，不自动提交实施结果。

实施与验证证据见 [专项验证](../../validation/PlatformKit-Containers.md)。本需求保留在 requirements，不把受阻检查改判为通过。

## 2026-10-17 需求调整

用户真机反馈姿态管线异常导致背景消失，已将预览改为独立原生最新帧订阅，Pose Tool 只更新有时限的骨架。此前同帧原子图像/姿态输出方案已被此设计替代，当前实现以 UI/Camera 与 Camera/Support README 为准。验证记录见 docs/validation/PlatformKit-Containers.md。

## 2026-10-17 原生流回归修复

已移除主录音新增的 MainActor 转发与第二级 FIFO；可选观察通过同步单代围栏广播。已增加姿态运行错误的有界恢复及过期媒体局部拒绝。自动化与未完成真机验收以 [验证记录](../../validation/PlatformKit-Containers.md) 为准。

## 2026-10-17 视觉静默退出补齐

已修复视觉输入/输出生命周期的终态送达竞态，补齐推理、输入和呈现的健康诊断与 Agent 异常/toast，并去除帧接纳对无关上下文写锁的等待。21 项定向含真实 Gateway 到 toast 链路通过，已安装并启动真机；实际 YOLO 故障原因仍待复现诊断，详见 [验证记录](../../validation/PlatformKit-Containers.md)。

## 2026-10-17 视觉订阅投递策略修复

针对用户复现的 queueFull、pipeline.failed，已让 VisionPerception 显式声明最新状态策略，并由 Gateway 对骨架、视线与姿态广播执行有界替换，保留现有 PlatformKit → Gateway → VisionPerception 的订阅关系。离散命令、定向消息和生成轮次保持各自交付契约。15 项专项及 67 项相关回归通过；修复版已安装，启动受锁屏阻断，持续真机验收待完成，完整检查仍有失败。详见 [验证记录](../../validation/PlatformKit-Containers.md)。

## 2026-10-17 Metal 渲染优化

按用户要求优化现有 Metal 合成，不改变相机与姿态独立输出或 Gateway/Action 边界。渲染器使用专用线程和 CAMetalDisplayLink，主线程只提交最新状态与布局；复用两个 GPU 骨架 buffer，缓存姿态网格，并在停止后等待真实 GPU 完成再交接图层。已补充同一生产渲染器的 macOS 原生合成回归。iPhone 真实相机、YOLO 并发的长时间稳定性和帧率验收仍待完成；构建、安装与各项自动化结果见 [验证记录](../../validation/PlatformKit-Containers.md)。

## UI 根与相机能力注入

✅ 已实现 UI 根及相机展示容器化。App 缓存并注入 CameraCapturing / CameraPresenting，提供 Coordinator 构造工厂；Actions 保留业务与帧协调，Agents 只提供延迟接入回调。UI 管理展示接纳/到期任务，Metal 保持原生视图所有权。其余 UI 状态本轮不迁移；不新增目录、目标或自动提交。

UI 根容器、接口注入和 App 构造工厂已落地；其余 UI 状态明确不在本轮。自动化、构建与尚未完成的真机验收以 [专项验证](../../validation/PlatformKit-Containers.md) 为准。

## 统一所有现有外部输入

✅ 业务意图/宿主事实与设备统一由 Gateway 生成 Signal；领域保留 schema，Gateway 不依赖业务模块。补齐绑定会话/incarnation 的宿主动态订阅和类型化传感器扩展。新增硬件驱动、远程传输、持久投递不属于本项。验证身份兼容、权限/容量/取消/代际、分发并分别记录完整检查及构建结果。
