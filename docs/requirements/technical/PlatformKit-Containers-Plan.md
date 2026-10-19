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

✅ ModelKit App 根容器化已实现（最新验证见末节）；完整检查的Metal／集成超时、Simulator CoreAI阻断和实际设备／模型验收仍未关闭。定向运行119项中117通过、2项外部资源验收跳过，签名真机构建通过，详见[验证记录](../../validation/PlatformKit-Containers.md)。

### UI 并发开销与渲染清理

✅ 已实现光环停止归还 GPU 槽位、锁保护线程与完成屏障；相机视频／骨架各复用一个可续期任务，保留独立750ms到期、更早期限及停止加入；频谱缓存固定配置。保持显示线程数量和帧率。

❌ 自动化、Simulator和签名构建的最新执行结果见验证记录；实际功耗／内存／真机流畅度仍需采集，不将构建当作通过。

✅ 已安装基线b846d32之后，已修复光环错误循环及历史详情迟到更新，缓存历史投影／异步目录解析，集中资源恢复与防抖保存。

❌ 新修改的构建／测试结果以验证记录为准；真机尚未安装本批修改。字幕和图片执行域调整、空闲日志及功耗优化以采样为前提，不在无证据时改写呈现时序。

✅ 已按用户要求试用原生TextRenderer字幕，替换双标签实现；保留新增淡入、最终修订、滚动与生命周期，不新增目录、编译目标或第三方依赖。构建、原生显示和性能分别验收。

✅ 用户已确认 TextRenderer 真机外观／滚动无异常；❌ 持续性能、功耗和量化对照尚待验收。实际构建、自动化及真机反馈范围见验证记录。

✅ 已实现首页导航生命周期修复（用户已确认深层导航及相机恢复行为正常，自动检查／构建和组合场景限制见验证记录）：离开首页暂停相机并保留启用意图，回首页恢复；Agent 记录→Assistant→更深详情保持聆听，App 后台仍停止。不得为只读历史调用设置变更停机。

### ModelKit 根容器化

✅ 已实现：App 持有实例级 ModelContainer，language／speech／vision／artifacts 子能力来自同根；移除进程级模型及语音配置。启动只注册轻量工厂／准备制品元数据，推理按需；后台同步关闭接纳并取消加入推理，保留权重与制品后台传输，恢复不重放；stop 终止并加入，旧端口不复用。ModelKit 只依赖自身／系统／已批准第三方，错误经中立回调进入现有 Gateway 通道，Signal 不进入模型模块。
实施基线 codex/storage-lifecycle-boundary；不整合或修改 main-sh 运控分支。保留既有 Provider 选择、资源容量和按需加载，生产消费者只注入窄接口，App 管理模型独立服务。

✅ 根与四子能力、实例私有默认装配、消费者注入、独立生命周期和故障回调已实现；❌ 真实模型／设备与后台制品恢复验收仍待完成。完整检查存在失败，Simulator受CoreAI阻断；实际证据见验证记录。

### 本地 LLM 4096窗口兼容

✅ 已实现：仅在 ModelKitGemma4 内裁剪 system 和最新5条非system消息（用户明确包含当前输入），为生成预留预算，实际完整提示词＋生成≤4096；不迁移到Agent，不修改云端／通用请求和持久历史。

✅ 纳入后端更小窗口限制：引擎配置、token裁剪及生成守卫使用同一有效预算，不超过4096；固定CoreAI版本iOS动态KV仅支持安全1024，保留上游保护。实际生成及长历史需真机复测，不将计数替身当作模型验收。

✅ 用户要求的排查版已移除本地Gemma所有system；❌ 真机对比待用户验收；保留实际窗口、最新5条消息上限及当前输入，不改Agent及云端。

### 首页模型准备门禁

✅ 已实现首页初次进入、导航返回及回前台检查当前模型；冷能力提前准备，已就绪不重复加载。实际加载仅展示双眼左右大小交替动画，无文字或手动取消；阻止新操作，保留设置、失败重试和已运行会话停止，失败异常由业务层呈现 Toast。准备状态与聆听状态独立，App拥有任务、取消加入和旧代际围栏；云端只代表客户端就绪，不伪造网络验证。原生模型性能与前后台／导航交互另行验收。

❌ 本轮真实模型准备时长、大小眼动画和导航／前后台的真机验收仍待用户验证；自动化及构建证据见验证记录。

### 蓝牙连接状态呈现

✅ Platform继续抛错，Gateway保留并标注连接条件；ApplicationControl把未连接／连接建立失败作为状态而非全局Toast，通过独立首页／设置呈现Action提交UI。首页灵动岛左侧：连接中蓝色闪烁、断开灰色、连接蓝色。真实传输及控制故障不一律抑制，状态显示不授权运动。

❌ 蓝牙图标位置／闪烁、真实机械臂连接／重连／断开及异常提示的真机验收待设备重新连接后执行。

✅ 已实现：四基础根完整保留原生异常，通过统一报告签名交宿主；Signal 摘要与原始异常分离，展示策略全部由业务上层决定。

## 四基础模块异常数据结构标准

✅ 已实现：StorageCore.StorageFailure、PlatformKit.PlatformFailure、ModelKit.ModelFailure、UI.UIFailure 各自拥有定义，不新增项目依赖、目录或目标。均为 Error/Sendable/CustomStringConvertible，字段和语义保持一致：

| 字段 | 契约 |
| --- | --- |
| code | 模块自有同形 Code 枚举，稳定技术分类，不从文案或反射类型名生成 |
| component / operation | 出错子能力与操作，非 Agent／业务会话身份 |
| message | 完整底层技术描述，业务上层决定是否展示 |
| underlying | 原始 Error 对象及其关联值，正常取消仍保留 |
| cleanupErrors | 全部附加清理错误，与原始主错误区分，禁止只保留首项 |
| source | fileID/function/line，采用默认参数捕获包装／报告处；不是原始 throw 堆栈 |

根生命周期采用throws(模块Failure)，原生报告端口统一包装；已有底层领域协议继续类型化抛错，不能以 SDK 全部 throw 已迁移为验收口径。相同模块错误再次上抛不重新包装／覆盖来源；新的清理错误追加保留。主错误为取消但清理失败仍按真实失败上报。正常控制结果只记录不广播；Gateway 仍独占 Signal 生成。移除被替代的根／清理专用复合错误类型，App仅连接结构投影。四种结构的字段／Code枚举及行为用同一自动化契约校验，防止未来漂移。

验证包括：四模块结构一致、代码分类、来源保留、NSError身份／关联值保留、多项清理错误、取消与取消后清理失败、模型／平台／存储／UI根抛错、Gateway稳定代码及蓝牙条件回归。完整检查、Simulator、签名真机构建分别记录；本轮不以硬件／模型验收代替自动化，也不自动提交实现后的修改。

✅ 已实现：首页加载眼睛修复为独立Expression状态Action。模型准备事实经Gateway→ApplicationControl→UI.Expression.setLoading→UI.home.expressions，动作接纳不等待加载结束或动画循环；同根revision拒绝迟到，退出与前后台清理覆盖。真机确认两个加载眼睛可见且未开启聆听也播放，终态恢复休眠／当前会话表情。

✅ 已实现：区分首页模型就绪检查与实际加载；仅真实加载或预热显示加载眼睛，不对暖模型检查播放动画。

✅ 首页模型检查与加载展示边界：检查和后端对象构造无加载表情／文字／按钮；ModelKit 真实无缓存资源加载分支报告起止，App 管理交互门并通过既有 Gateway→ApplicationControl→Action 链路呈现；ready／unmanaged 不发加载。失败只提供重试按钮，异常保留业务 Toast；不提供手动取消。

❌ 提示音启动和录音开启延迟优化尚未完成硬件验收，现已撤回实验性音频图与会话复用路径；取消仍等待原有原生播放器清理。


✅ 大模型请求等待复用大小眼动画（实现完成，真机等待及首输出恢复已确认；失败／取消场景未实测）：前台请求开始至首个非空输出，终态／取消清理；独立于模型准备状态，不显示加载文字和取消按钮。


✅ 聆听路径清理（实现完成，设备验收待执行）：按压预备不停止设备；真实启动去除同一区间重复等待；共用私有提示音缓存和同步音频会话配置；临时计时收敛为总区间，保留权限、首帧、取消、错误和播放完成契约。
