# SpeechSynthesis — 定向文本合成与有界音频生产

## 角色容器

[SpeechSynthesisContainer.swift](SpeechSynthesisContainer.swift) 是 AgentContainer 的稳定子能力。独立持有合成角色注册，与感知容器分别管理生命周期。endSession 仅移除当前合成角色，允许后续私有语音会话；根 stop 永久关闭容器。TTS 与 AudioCache 属于角色，播放归 Actions。

生命周期由[模块根](../README.md#agent-container)统一编排；子容器能力不授予执行权。

## 职责与注入能力

构造注入 ModelKit `SpeechSynthesisCapability`、StorageCache `AudioCache`、私有 Context 与通信配置。只接收授权定向合成／取消消息，不需要 UI 或 PlatformKit 容器，不开启麦克风、不播放音频，不运行普通 Chat。

## 文件与职责

| 文件 | 职责 |
| --- | --- |
| [SpeechSynthesisAgent.swift](SpeechSynthesisAgent.swift) | 定向 TTS FIFO、音频缓存所有权及 producer 失败 |
| [SpeechSynthesisProcessing.swift](SpeechSynthesisProcessing.swift) | 合成角色 Context、输入预处理与请求验证 |

## 外部关系（一层）

```mermaid
flowchart LR
 A["SpeechSynthesis"]:::agent
 G["Gateway：调用／Signal／反馈"]:::gateway
 C["AgentCore：身份／契约"]:::host
 H["Agents 根级装配：构造与生命周期"]:::host
 H -.-> A
 A --> C
 G -->|"授权定向消息"| A
 M["ModelKit.speech：SpeechSynthesisCapability"]:::model
 A <--> M
 S["Storage.cache.audio"]:::storage
 A -->|"预留句柄／写 PCM／保留原始失败"| S
 subgraph Peers["其他 Agent：仅经 Gateway 通信"]
 AS["Assistant"]:::agent
 end
 AS -->|"speech.synthesize／speech.cancel"| G

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

Gateway递送定向合成消息，并执行本角色的UI.Island内部展示工具；descriptor.outputs仅开放toolCall，内部工具不暴露给模型。播放Action仍由请求方的输出执行链调用，SpeechSynthesis通过注入的播放事实回调管理自己的说话展示，不让Assistant代发。

## 内部结构与播放衔接

```mermaid
flowchart LR
 M["注入 ModelKit.speech.TTS"]:::model
 S["注入 Storage.cache.AudioCache"]:::storage
 subgraph Role["SpeechSynthesis"]
 A["定向身份校验／接纳时预留句柄"]:::agent
 Q["有界 FIFO／一个 producer"]:::agent
 B["Context Builder／输出格式与序号校验"]:::agent
 C["取消／失败／终态加入"]:::agent
 end
 G["Gateway：speech.synthesize／cancel"]:::gateway
 G --> A --> Q --> B
 M <--> B
 A --> S
 B -->|"PCM／原始终态错误"| S
 C --> Q
 S --> X["Actions：Speech.Playback.speak 读取缓存"]:::action
 X --> P["Platform.audio：播放／drain／停机"]:::platform
 X --> U["UI.home：播放业务呈现"]:::ui
 classDef ui fill:#e0f2fe,stroke:#0284c7,color:#0c4a6e
 classDef platform fill:#dcfce7,stroke:#16a34a,color:#14532d
 classDef model fill:#f3e8ff,stroke:#9333ea,color:#581c87
 classDef storage fill:#fef3c7,stroke:#d97706,color:#78350f
 classDef agent fill:#eef2ff,stroke:#6366f1,color:#312e81
 classDef gateway fill:#ffedd5,stroke:#ea580c,color:#7c2d12
 classDef action fill:#ffe4e6,stroke:#e11d48,color:#881337
 classDef host fill:#f1f5f9,stroke:#64748b,color:#334155
```

图中缓存之后是下游播放链，非本角色调用；PCM 生产终态不等于扬声器 drain。Assistant 的 caption/synthesis/playback 分段与 Channel 屏障决定播放顺序。

## Admission and ownership

speech.synthesize carries audioID, nonblank text ≤2000 UTF-8 bytes and locale auto/zh-CN/en-US, with ≤16 KiB encoded input. Reserve the unique handle before returning admission. Ownership is trusted sender + session + original parent input; cancel validates the same tuple and bypasses FIFO capacity.

One serial synthesis worker has at most 32 queued/in-flight admissions in addition to the active producer, subject to the shared handle limit. The shared audio store independently permits 32 live handles including queued, producing and playing audio. Overflow rejects; admission is not proof that PCM exists. Semantic text segments belong to the requesting role; model adapters handle provider language/length constraints.

## Production and failure propagation

Build the request from role context and validate request identity, mono Float32, stable format, increasing sequence, explicit finished event, nonempty audio and ≤8 MiB total output. Convert ModelKit.AudioFrame into StorageCache.AudioFrame without a dependency from Storage to ModelKit. Invalid producer output throws SpeechSynthesisError.invalidOutput; provider and storage errors retain their original types.

Synthesis waits for provider completion, failure or owner cancellation without an Agent timer. Cancellation fails the audio handle, wakes readers and joins the producer. Failed handles retain the original error until scope cleanup or bounded metadata eviction; no audio/cache TTL or reader timeout exists. Already audible samples cannot be retracted.

The worker advances after synthesis terminal state without waiting for playback. Pause retains queued requests and lets an already active producer finish; resume drains the FIFO. Stop joins work and closes/fails owned handles. Cancellation cannot discard another source's request. Context write failure prevents dependent synthesis; recent evidence retains 256 summaries. Restart does not restore audio or replay speech.

## 错误呈现与接口

播放清理后的文案适配由 [SpeechPerception/SpeechPlaybackFailure](../SpeechPerception/SpeechPlaybackFailure.swift) 拥有，合成角色保留 producer 原始失败，不依赖 UI 或原生播放。通信见 [Agent.json](../../Resources/Agents/SpeechSynthesis/Agent.json)。

## Passive container state

stateSnapshot projects local installation/closure and existing work or Agent lifecycle/queue counters directly from memory. Reading starts no role, persistence restoration or inference. Initialization remains in the existing owner lifecycle. The root catalog binds independent readers without sampling roles or maintaining another mutable role-state registry.

## 自有灵动岛与播放事实

角色在生产工作开始/完成/失败时管理合成岛；实际播放器在首个有效PCM及drain/失败清理后，加入App绑定的playbackChanged(audioID,active)回调。SpeechSynthesis管理当前播放身份，旧audioID结束不能撤下新播放，生产完成不等于播放完成。播放优先显示“正在说话”和频谱指标，无播放而仍有生产时显示合成。频谱数值由真实播放器直送UI专用数据端口，本角色只提交语义内容。

内部UI.Island工具用自身consumer执行，成功/失败/异常由共享发布机制处理并通过presentationFailure及容器runtime公开，不经Assistant或模型反馈。stop关闭角色准入，加入生产任务和最终展示end后才退休身份；迟到播放事实不复活活动。一个串行producer、一个当前播放身份和一个最新待发展示维持有界生命周期。
