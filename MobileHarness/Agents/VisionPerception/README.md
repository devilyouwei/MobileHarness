# Vision Perception

Purpose: own shared visual perception and its skeleton visualization. Design goals: one inference per accepted latest frame, typed observations for business subscribers, and direct UI Tool calls through OutputGateway. Camera motion and robot policy do not belong here.

```mermaid
flowchart LR
    InputGateway --> Filter[Grayscale change admission]
    Filter --> Latest[One active / one latest pending frame]
    Latest --> Model[Injected PoseCapability]
    Model --> Observation[Up to 300 people / upright pixel joints]
    Observation --> Pending[One latest pending observation]
    Pending --> Publisher[One publication worker]
    Publisher --> Publication[OutputGateway / InputGateway]
    Publication --> Subscribers[Optional business subscribers]
    Observation --> Overlay[Up to six people / bounded display coordinates]
    Overlay --> Generator[Code-owned UI.showPose permission]
    Generator --> Output[Latest skeleton / gaze pair]
    Output --> Gateway[OutputGateway / ToolRuntime]
    Gateway --> Action[UI.showPose Void tool / injected presentation handler]
```

✅ VisionPerception.agent.json v5 contains communication policy and empty model catalogs. Code declares UI.showPose as an internal Tool with no Channel. Swift projects observations into PoseOverlay JSON (maximum 3000 bytes), constructs a typed internal ToolCall and emits one ToolCall per result. Empty people clears the overlay. No direct UI call or per-frame agent.finished is emitted; moveEyes is a separate resolved Action. The registered Void handler completes without ToolResult feedback.

✅ Raw inputs have increasing sequence/timestamps and matching sessions. Grayscale compares previous examined frames. One worker processes a frame; one latest pending frame replaces older pending input. Pause suspends dequeue, stop cancels/joins inference and suppresses late outputs. Shared observations retain up to 300 people independently of the six-person display limit.

✅ Publication uses a separate Agent-owned worker and one latest pending observation. Slow subscriber admission does not hold the inference worker or UI output. Pending observations are replaced explicitly (publicationReplacements); expired pending observations are skipped. Missing subscribers is allowed; unexpected publication errors still fail the Agent and are surfaced through terminal control. Pause holds pending publication; stop cancels and joins inference and publication before finishing outputs.

✅ Presentation output is a capacity-two bufferingNewest stream: every inference emits showPose followed by moveEyes, including neutral gaze. Only these two replaceable presentation states can be superseded, with separate overlayReplacements/gazeReplacements counters; arbitrary commands fail overflow. App awaits the Tool and joins/retires each admitted Action before consuming the next state. This completion barrier is outside the replaceable buffer, so no accepted Action loses its finish. Terminal error may follow one buffered display state, finishes the stream, and cannot be overwritten by later results. OutputEnvelope holds correlation metadata rather than raw input media. A publication may retain its parent frame until delivery completes; active/pending publication slots bound that lifetime.

✅ FrameChangeConfiguration keeps adjacent-examined-frame comparison and optional minimumInterval. Optional maximumRefreshInterval bounds admission starvation: after that interval, the next newly captured frame is accepted even with unchanged gray samples. App uses 0.1 seconds; nil preserves pure change-triggered behavior. There is no timer, no repeated sequence and no inference without a new frame. This is an admission policy, not a guaranteed FPS or deadline under load; idle-camera inference and power use can increase.


❌ Separate face detector, identity recognition, depth, robot movement and physical-device tracking acceptance.


## 输入、订阅与输出契约

以 [VisionPerception.agent.json](VisionPerception.agent.json) 和 [VisionPerceptionAgent.swift](VisionPerceptionAgent.swift) 为准。公共信封见 [Agents 输入输出约定](../README.md#输入输出文档约定)。

| 接收方式 | contract / version / kind | source / topic | 处理 |
| --- | --- | --- | --- |
| 静态订阅 | `media.image / 1 / image` | `phone.camera / media.image` | `AgentInput.payload = .image(ImageInput)`，来自 App PhotographySession 的摄像帧适配，经 InputGateway 路由。匹配 session、严格递增 sequence、非倒退 timestamp，并检查接纳期限。 |
| 初始化注入，不是业务消息 | `PoseCapability`、`resolveImage`、`FrameChangeConfiguration` | App | 能力执行一次姿态推理，resolver 将传输附件转换为 ModelKit ImageFrame；筛帧配置控制 3% 阈值及 App 默认 100ms 新帧刷新。 |
| 生命周期，不是订阅 | `bind / start / pause / resume / stop` | App / AgentManager | 注入消息端口、管理两条有界 worker；没有外部指令或 ToolResult 输入。 |

```swift
// 结构摘要；真实定义在 AgentCore/ImageInput.swift。
ImageInput {
    width: Int; height: Int  // 正向推理图像的尺寸
    sequence: UInt64; timestamp: TimeInterval
    rotation: Int           // 传感器图像到正向图像的顺时针 90° 次数，0...3
    content: .rgb(Data)
          或 .sampled(gray64: Data, attachment: any ImageAttachment)
}
```

RGB 路径为正向、未镜像 RGB8，宽高各 1...640，字节数必须为 width × height × 3。当前摄像头走 sampled 路径：gray64 固定 4096 字节，附件不透明地持有原生帧；宽高各 1...4096、总像素不超过 4194304。Gateway 不解析原生附件或执行模型预处理；App 注入 resolver。默认 image 接纳期限 1 秒，过期帧不进入推理/输出；灰度筛选发生在 Agent 内。

```mermaid
flowchart LR
    Camera[PlatformKit camera] --> App[PhotographySession: gray64 + attachment]
    App -->|media.image| IG[InputGateway]
    IG --> Filter[VisionPerception: frame admission]
    Filter --> Latest[One active + newest pending frame]
    Latest --> Pose[PoseCapability]
    Pose --> Obs[PoseObservation: up to 300 people]
    Obs --> Pub[Independent bounded publisher]
    Pub -->|vision.pose| OG1[OutputGateway]
    OG1 --> IG[InputGateway]
    IG -.-> Future[Optional business subscribers]
    Obs --> Projection[PoseOverlay: up to 6 people]
    Projection -->|UI.showPose ToolCall| OG2[OutputGateway]
    OG2 --> TR[ToolRuntime: completion-only]
    TR --> UI[MainActor overlay state]
```

### 共享感知数据：vision.pose

通过绑定端口发布 `.pose(PoseObservation)`，source 为 `visionPerception`，contract/topic 为 `vision.pose`、version 为 1。当前运行中的其他 Agent 没有订阅它；无订阅者不阻止骨架显示。未来业务 Agent 需要在自己的 JSON 中声明订阅。

```swift
PoseObservation {
    width: Int; height: Int           // 1...4096
    sequence: UInt64; timestamp: TimeInterval
    rotation: Int                    // 0...3
    people: [[Joint]]                // 0...300 人，每人恰好 17 个 COCO 关键点
}
Joint { x: Float; y: Float; confidence: Float }
```

x/y 是正向、未镜像图像的像素坐标，以左上角为原点，必须有限但可在图像外；confidence 为 0...1。共享观测只提取关节点，没有模型结果中的 bounding box、整个人置信度，也没有 tracking ID、动作指令或原始图像字段。编码校验上限 256 KiB，默认接纳期限 1 秒且受父输入期限约束。`people: []` 表示这一帧未检测到人，不是漏发数据。独立发布 worker 保留一项活动发布和一项最新等待观测，通信层不再合并状态，最新状态策略由 Agent 自己负责；不能依赖收到每帧。

people 内关节点数组的下标 0...16 固定为：nose、leftEye、rightEye、leftEar、rightEar、leftShoulder、rightShoulder、leftElbow、rightElbow、leftWrist、rightWrist、leftHip、rightHip、leftKnee、rightKnee、leftAnkle、rightAnkle。左右以被识别者自身为准；显示投影保留相同顺序。

### 显示数据：UI.showPose

代码内部权限产生 `ToolCall(id: UUID, toolPath: "UI.showPose", arguments: ["payload": String])`。payload 是以下 PoseOverlay 的 JSON 文本，最多 3000 UTF-8 字节；外层 arguments 的值仍是字符串。

```json
{"sequence":42,"timestamp":123.5,"rotation":1,"people":[]}
```

这是有效的清空骨架示例。非空时 `people` 为最多六个人的二维数组，每人必须有完整 17 个 COCO 点；单个点编码为 `[x, y, confidence]`，例如 `[5000, 2500, 900]` 表示图像宽度 50%、高度 25%、置信度 0.9，不是一个完整人的 payload。

| 字段 | 类型、单位与显示策略 |
| --- | --- |
| sequence / timestamp / rotation | 沿用输入帧的序号、秒级采集时间和旋转信息；UI 用帧序号拒绝迟到结果。 |
| joint.x / joint.y | Int，归一化坐标 ×10000；限制 -10000...20000，图外点 confidence 置 0。 |
| joint.confidence | Int，0...1000；从共享观测的 Float 量化。 |
| people | 从模型结果取前六人，按其置信排序；显示镜像和裁剪由预览层坐标转换处理。共享观测仍可保留最多 300 人。 |

Tool 经 `outputs → App transport pump → OutputGateway → ToolRuntime → MainActor handler` 覆盖骨架状态。无 Channel、无 Action 队列、无 ToolResult 回流；等待 handler 完成不等于等待屏幕绘制完成。外层 OutputEnvelope 用 inputID/sessionID 关联，Vision 的 envelope.sequence 和 payload.sequence 均为输入帧序号。

### 其他输出与 send 边界

| 方向 | 数据标准与语义 |
| --- | --- |
| Action 输出 | `moveEyes → UI.moveEyes / Gaze`，`parameters["x"] / ["y"]` 为数值的十进制字符串，目标范围各为 -1...1；由 FaceGazeTracker 根据本帧脸部点位生成，未锁定目标时回中。它是显示方向，不是关节点像素坐标。与同一帧的 showPose ToolCall 组成可替换状态对。 |
| control 输出 | 推理失败发 `control("agent.error: pose processing failed")` 并终止流；不发每帧 `agent.finished`。终态控制不能被后续骨架覆盖。 |
| publish | `communication.publications` 仅有 `vision.pose`；typed payload、坐标单位、人数与容量按上文“共享感知数据”段落。该发布与骨架 ToolCall/眼睛 Action 分离。 |
| send | `communication.sends = []`，不向其他 Agent 定向发送消息；当前也没有其他业务 Agent 订阅 `vision.pose`。 |

JSON `actions / tools` 均为空；代码声明 UI.moveEyes（Gaze）与 UI.showPose 内部权限。❌ 摄影决策、机械控制与跟踪身份不在该 Agent 内实现。

## Eye attention policy

✅ FaceGazeTracker uses the existing YOLO Pose observation, without another model. At least two of nose/eyes must be visible with confidence ≥0.45; ears help estimate face span. Initial selection prefers larger, reliable, central faces. Subsequent selection uses nearest spatial association with a size-bounded gate, holds brief occlusion, starts recentering after 350ms without a match, and releases the lock after 550ms. Array reordering does not switch attention. This is geometric association, not identity tracking; crossing faces can still exchange the lock.

✅ A deadband and elapsed-time adaptive low-pass filter suppress jitter while responding faster to larger changes. Rotation resets association; upright coordinates are never rotated twice. App supplies front-camera mirroring once. x/y are screen directions in [-1,1], with 20% gain and clamping; display crop is not an exact projected-point overlay. SwiftUI handles continuous spring interpolation independently of expression. No synthetic random gaze or third-party animation library.

✅ Tracker state is one face, timestamps and one filtered target; candidate work is bounded by the existing 300-person observation limit. Updates are driven by new pose results; no extra task, timer or frame replay. Camera shutdown, failure and session replacement reset UI gaze. A stalled source with no new result has no perception-driven timeout yet (❌).

```mermaid
flowchart LR
    Pose[Shared pose observation] --> Face[Confident facial points]
    Face --> Lock[Spatial lock / occlusion hold]
    Lock --> Filter[Deadband / adaptive smoothing]
    Filter --> Resolve[Code-owned gaze Action]
    Resolve --> Gateway[OutputGateway]
    Gateway --> Channel[Gaze Channel / UI module exclusion]
    Channel --> Action[UI.moveEyes validation]
    Action --> Scene[Active camera session / sequence check]
    Scene --> Eyes[Native spring / stable eye shapes]
```
