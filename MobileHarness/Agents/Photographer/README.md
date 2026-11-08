# Photographer — 摄影事务与机械跟踪

## 角色容器

[PhotographerContainer.swift](PhotographerContainer.swift) 是 AgentContainer 的稳定子能力。持有角色执行会话、相机 UI 控制和跟踪输出生命周期。CameraCoordinator 由 Actions 实现，经根连接；跟踪 attach／detach 属于会话，停止加入角色和跟踪工作。

生命周期由[模块根](../README.md#agent-container)统一编排；子容器能力不授予执行权。

## 职责与注入能力

确定性角色，拥有相机 UI 请求、低频相机事实和跟踪策略，不运行普通 Chat，不消费视频帧。构造注入 `UICameraContainer`、可选 `UIAlbumContainer`、私有 `AgentContextRepository`、`controlAvailable` 只读能力及观察失败回调；不注入 ModelKit 或原生相机控制接口。StorageCore 的中立值依赖不等于持有 Storage 根。

## 文件与职责

| 文件 | 职责 |
| --- | --- |
| [PhotographerAgent.swift](PhotographerAgent.swift) | 相机意图、固定任务和姿态跟踪的角色生命周期 |
| [PhotographerCameraInputs.swift](PhotographerCameraInputs.swift) | 相机意图、低频状态观察及本角色固定任务解码 |
| [PhotographerCameraWorkflow.swift](PhotographerCameraWorkflow.swift) | 单槽相机命令、身份验证及结果关联 |
| [PhotographerExecutionSession.swift](PhotographerExecutionSession.swift) | 摄影注册、受保护输出消费及停止加入 |
| [PhotographerProcessing.swift](PhotographerProcessing.swift) | 摄影私有状态、阶段与输入预处理 |
| [PhotographerTrackingPolicy.swift](PhotographerTrackingPolicy.swift) | 新鲜姿态选择和跟踪策略，不操作硬件 |
| [PhotographerUI.swift](PhotographerUI.swift) | camera 请求与低频事实的角色直接订阅 |

## 外部关系（一层）

```mermaid
flowchart LR
 A["Photographer"]:::agent
 G["Gateway：调用／Signal／反馈"]:::gateway
 C["AgentCore：身份／契约"]:::host
 H["Agents 根级装配：构造与生命周期"]:::host
 H -.-> A
 A --> C
 A <-->|"受身份绑定的输出与反馈"| G
 U["UI.camera"]:::ui
 U -->|"主动订阅 requests／observeFacts"| A
 X["Actions：Camera／NexArm 能力声明"]:::action
 A -.-> X
 subgraph Peers["其他 Agent：仅经 Gateway 通信"]
 V["VisionPerception"]:::agent
 AS["Assistant"]:::agent
 end
 V -->|"vision.pose"| G
 AS -->|"task.request／input／cancel"| G
 G -->|"task.progress／result"| AS

 classDef ui fill:#e0f2fe,stroke:#0284c7,color:#0c4a6e
 classDef platform fill:#dcfce7,stroke:#16a34a,color:#14532d
 classDef model fill:#f3e8ff,stroke:#9333ea,color:#581c87
 classDef storage fill:#fef3c7,stroke:#d97706,color:#78350f
 classDef agent fill:#eef2ff,stroke:#6366f1,color:#312e81
 classDef gateway fill:#ffedd5,stroke:#ea580c,color:#7c2d12
 classDef action fill:#ffe4e6,stroke:#e11d48,color:#881337
 classDef host fill:#f1f5f9,stroke:#64748b,color:#334155
```

角色间消息经 Gateway 递送；基础能力通过构造注入，输入订阅由角色持有。角色、Skill 与 Task 授权归 Agents；Actions 来源的协作接口由 App 以中立窄端口绑定，Agents 不导入 Actions、CallRuntime 或 ExecutionRuntime。

## 内部结构与执行链

```mermaid
flowchart LR
 subgraph Input["直接输入"]
 U["UI.camera.requests／低频相机事实"]:::ui
 V["vision.pose：Gateway 投递"]:::gateway
 Q["注入跟踪可用性查询"]:::host
 end
 subgraph Role["Photographer"]
 H["PhotographerUI：类型化处理"]:::agent
 W["CameraWorkflow：一个摄影事务"]:::agent
 T["TrackingPolicy：新鲜姿态／目标／节奏"]:::agent
 C["私有 Context／固定 Task 协调"]:::agent
 end
 U --> H --> W
 V --> T
 Q --> T
 C <--> W
 W --> G["Gateway"]:::gateway
 T --> G
 G --> CA["Camera.Capture.open<br/>Camera.Capture.close<br/>Camera.Capture.flip<br/>Camera.Capture.retry<br/>Camera.Capture.savePhoto<br/>Camera.Capture.ignorePhoto"]:::action
 G --> NX["NexArm.Tracking.aim"]:::action
 CA --> P["Platform.vision：采集／镜头；Photos／文件保存"]:::platform
 CA --> UI["UI.camera：预览／照片／事务反馈"]:::ui
 NX --> B["Platform.connectivity：受保护机械臂控制"]:::platform
 classDef ui fill:#e0f2fe,stroke:#0284c7,color:#0c4a6e
 classDef platform fill:#dcfce7,stroke:#16a34a,color:#14532d
 classDef model fill:#f3e8ff,stroke:#9333ea,color:#581c87
 classDef storage fill:#fef3c7,stroke:#d97706,color:#78350f
 classDef agent fill:#eef2ff,stroke:#6366f1,color:#312e81
 classDef gateway fill:#ffedd5,stroke:#ea580c,color:#7c2d12
 classDef action fill:#ffe4e6,stroke:#e11d48,color:#881337
 classDef host fill:#f1f5f9,stroke:#64748b,color:#334155
```

## 请求、事实与跟踪

`PhotographerUI.swift` 在 start 建立请求与事实消费，按真实 Camera Tool 结果推进 open/close/flip/retry/save/ignore。回执在原生结果及角色终态完成后结束，照片处置使用真实 previewID，保存回执另含持久 mediaID；取消加入调用后 retire 状态。事实不通过 camera.state Signal 镜像；相机上下文在模型请求时读取所属容器快照。

Assistant 的 photography Skill 可以直接调用 Camera Actions，不必须委派 Photographer Task。跟踪另行消费 VisionPerception 的 `vision.pose`：前台、连接与准入满足且姿态新鲜才发内部 aim。输出使用 PlatformKit 的位置更新建议间隔 50 ms，最多 20 Hz（实际受姿态产出频率限制）；滤波采用按观测时间计算的 120 ms 时间常数，积分使用实际目标间隔且至多 0.2 秒，画面中心立即停止累加，重复/倒退时间不推进。角色保留画面死区、构图窗口和追随增益，提供 base/pitch 目标；这些是摄影策略，设备编码器范围、运行参数和通信上限由 PlatformKit 拥有，Actions/NexArm 编译有限位置包。角色不转换速度方向位、不切换舵机模式。资源冲突与执行生命周期仍归 Actions/NexArm；设备位置模式为运行前提，软件限位不等于硬件保护。

## 状态、生命周期与失败

跟踪派发仅保留正在执行一个和待执行最新一个目标；新意图覆盖未执行旧意图，饱和计数 `supersededTrackingTargets` 记录替换。已开始执行的调用保持完成/失败语义；detach 清空单槽并取消加入 worker。普通摄影事务不采用覆盖语义。

输出默认 256；短接纳等待容量 32；最近 4096 条证据／消费批次滚动保留并计数，不淘汰待执行事务。每个 UI 源普通未终态请求最多 64，控制独立单槽；相机事务自身只允许一个 pending。

pause/stop 关闭接纳、取消并加入订阅／事务／跟踪；resume 加入旧消费者后重新订阅。旧 token、会话、代际或调用反馈不能更新新请求。事实源非取消意外结束报告 `consumerEnded`；正常暂停和停止不生成故障。Context 提交失败显式传播，不重放不确定设备效果。

通信以 [Agent.json](../../Resources/Agents/Photographer/Agent.json) 为准，函数契约见 [Camera](../../Actions/Camera/README.md)、[NexArm](../../Actions/NexArm/README.md)。

本角色通过 [固定任务准入](../Support/Communication/README.md#固定任务准入) 接收 Assistant 委派。PhotographerCameraIntent.taskMessage 只解释 photography.camera；PhotographerCameraWorkflow 要求私有 cancel 来自本地 runtime 且匹配根会话与请求身份，远程业务载荷不能获得清理权。Task 取消通过 task.cancel 契约进入协调器。

## 基础相册实施契约

订阅UI.album并经身份绑定Gateway执行内部Album操作，根持有导入导出任务，停止取消并加入；相册不依赖相机开启。

## Execution ownership and lifecycle

Camera/device execution and CameraInteractionWorkflow belong to ActionsContainer. Photographer receives narrow App-bound access interfaces and UI-owned controls, owns authorization/tracking intent and cancels its execution scopes explicitly. Private album attachments validate request/session independently of role permission.

## Passive container state

stateSnapshot projects local installation/closure, Agent lifecycle/queue counters and initialized committed task/Skill fields without message content. residentContext() reads the repository’s last committed memory only; context fields are unknown before initialization. Agent start owns initialization/restoration and its failures. The root catalog binds independent readers without sampling roles or maintaining another mutable role-state registry.

The fixed camera input workflow includes takePhoto for the window shutter. Its authorized Tool is Camera.Capture.takePhoto, sharing the existing capture/receipt/ownership pipeline. Camera window management is handled by ApplicationControl; Photographer retains camera and album business requests.

Typed camera intent also includes perceptionOpen/perceptionClose/perceptionFlip/perceptionRetry, mapped to fixed Camera.Perception.openVision/closeVision/flipVision/retryVision calls. The same bounded request workflow and Gateway authorization apply. Pose/tracking scope exists independently of the photo window; stopping it joins tracking output before a replacement scope. Root model requirements include vision only while background visual demand is enabled.

## Capture enhancement requests

CameraInput maps to a bounded PhotographerCameraIntent containing optional complete CameraCaptureSettings or a UUID recordingID. Intent validation enforces operation-specific fields before the role invokes fixed Capture.configure/cancelCapture or Video.startRecording/stopRecording/saveVideo/ignoreVideo. For startRecording the fixed Tool supplies waitForCompletion=false, acknowledging native startup without retaining the request until the movie ends. UI stop remains a separate ToolCall; it does not enter ChannelScheduler or model inference and can stop an Assistant's scheduled recording whose default completion waits for the ready file. The single pending request and source/session checks are shared with photo/lens controls; file/native work remains in Actions. UI countdown cancellation cancels and joins its existing request, or submits the fixed cancelCapture operation when the countdown was started elsewhere.

## 自有摄影岛

Photographer在既有camera.observeFacts输入中选择倒计时、照片处理、录像和待处置内容，以自身Gateway身份调用内部Island工具。没有独立的跨角色UI观察器；具体内容在PhotographerUI，通用发布/重试机制在Support。暂停输入撤下活动；停止在权限退休前加入最终end，presentationFailure在角色和容器runtime可查。相机窗口、保存/忽略退场及提示音仍是Camera Action事务的一部分，实际执行回执不由展示推断。

Photo disposition intents carry previewID. UI and model captures share Camera-owned preview State without Assistant delegation. Persistent savedMediaID is separate. Disposing of an older cached image does not change another image currently displayed by UI.

UI camera requests capture previewSession before admission. Photographer attaches it to the internal Tool envelope for Camera validation, preserving the user-owned result flow without model feedback. Gallery byte reads remain a typed Camera-owned read capability; browsing is not a model input.
