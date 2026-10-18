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

## Container failure channel

Implemented: foundation-owned injected callbacks, App-scoped Gateway journal and bounded publisher, passive Agent subscriptions and existing issue/toast projection. Preserve original throws, cancellation and real cleanup. No new directory/module; no implicit device restart or model inference. Validate source/scope, pre-start/shutdown, capacity/coalescing, root isolation and end-to-end delivery; retain failures honestly.

### ApplicationControl 统一异常展示

✅ 容器/执行异常通过 Signal 交给 ApplicationControl，策略不调用模型或 Storage；移除快照直达首页的容器异常支路。覆盖重复、过期、未运行、暂停、错误来源、展示失败防递归以及停止清理；保留 App 启动失败兜底。

### UI 全量容器化

✅ 八个 UI 子容器统一创建应用级展示状态，App 管理生命周期；删除消费者重复状态和直接写入，保留 revision/generation/会话围栏。后台只冻结实时输出，导航/草稿/历史保留，资源设备及异常可更新；停止取消并加入展示期限和动画等待。覆盖实例同一性、无效果初始化、失活/停止迟到拒绝、前后台、旧根隔离、既有呈现和 Metal 回归，运行完整检查与构建，安装真机并区分自动化/物理验收。本轮不提交。

❌ UI 全量容器化的完整自动化、iOS 构建与真机手工验收以最新验证记录为准，尚未以旧证据判定通过。


### 真机反馈修复

✅ 已实现独立交互提示/忙碌状态、字幕与原生效果观察隔离、图层尺寸变更判断和离主线程 FFT。正常音频释放与真实失败原因分开，真实缺失仍抛错并上报；路由事实不直接报告容器失败，用户已确认无误报。相关历史失败及中间安装结果保留在专项验证，不作为最新版本验收。

✅ 逐段时序定位回复开始时约700ms音频输出启动阻塞主线程；原生输出图移交 PlatformKit 私有 actor，停止/token/真实完成及缓冲上限保留。频谱改为常驻原生图层和 Core Animation 插值，UI 无 Canvas；八个子容器原本已在根构造时全部创建，不在 UI boot 激活设备。

❌ 最新采样证明音频启动等待时相机仍连续交付，但另有一次原生捕获同步暂停待关联操作；新版完整手工验收、Metal 自动化失败及全量集成失败仍未关闭。最新签名构建及设备安装通过，Simulator 的 CoreAI 阻断仍未解决。详见 [验证记录](../../validation/PlatformKit-Containers.md)。本轮保持不提交。


### UI 代码与文档整理

✅ 已清除视觉演示、模拟记录、临时性能对比和已替代的坐标转换；同类状态／端口归并，导航归根、检测归诊断、眼睛与频谱职责分离。全部 UI README、工程导航、源码守卫及格式已对齐，保留真实诊断和原有能力／回执，不增加目录／target／依赖、不自动提交。12项定向回归和签名真机构建通过，工作区既有修改保持。

❌ 完整检查的 Metal 挂载、集成超时及 Simulator CoreAI 阻断仍单独记录；本轮未重新安装／执行真机交互验收，清理不代替性能或物理验收。详见 [验证记录](../../validation/PlatformKit-Containers.md)。

### 其他基础模块边界与冗余审查

✅ PlatformKit 相机、PCM音频、提示音、触觉及串口通过协议端口提供，具体驱动由模块内创建和缓存；删除未使用的音频预热／游标，原生设备事实与实际错误分离。Storage 共享错误集中、私有接纳只抛错并由公开操作报告；ModelKit 复用一次恢复计划读取，保留有效的旧暂存迁移。文档、消费者及源码守卫已对齐，Signal 转换仍在 Gateway，无新目录／target／依赖，未提交。

❌ ModelKit App 根容器化仍独立待完成；完整检查的Metal／集成超时、Simulator CoreAI阻断和实际设备／模型验收仍未关闭。定向运行119项中117通过、2项外部资源验收跳过，签名真机构建通过，详见[验证记录](../../validation/PlatformKit-Containers.md)。

### UI 并发开销与渲染清理

✅ 已实现光环停止归还 GPU 槽位、锁保护线程与完成屏障；相机视频／骨架各复用一个可续期任务，保留独立750ms到期、更早期限及停止加入；频谱缓存固定配置。保持显示线程数量和帧率。

❌ 自动化、Simulator和签名构建的最新执行结果见验证记录；实际功耗／内存／真机流畅度仍需采集，不将构建当作通过。

✅ 已安装基线b846d32之后，已修复光环错误循环及历史详情迟到更新，缓存历史投影／异步目录解析，集中资源恢复与防抖保存。

❌ 新修改的构建／测试结果以验证记录为准；真机尚未安装本批修改。字幕和图片执行域调整、空闲日志及功耗优化以采样为前提，不在无证据时改写呈现时序。
