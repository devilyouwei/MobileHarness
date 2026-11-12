# Communication — 通用消息、Task 与投递回执

## 职责与外部关系

定义不可变消息、精确通信声明、scoped Task 与投递证据，不运行传输 Worker，不认识语音／姿态等业务 schema。Agents InputGateway owns role policy, semantic validation and receiver selection; Gateway SignalTransport owns generic endpoint/envelope validation and bounded transport. Receiving roles own processing and business terminal state.

```mermaid
flowchart LR
    subgraph Cognition["AGENTS · Communication semantics"]
        A["Producing role"]:::agent
        P["InputGateway / OutputGateway<br/>Policy · Schema · Receiver selection"]:::agent
        C["AgentCore.Communication<br/>Contracts · Task · Causal evidence"]:::agent
        R["Receiving role"]:::agent
        A -->|CommunicationAction| P
        C -->|used by| P
    end
    G["Gateway.SignalTransport<br/>Bound endpoints · Opaque payloads"]:::gateway
    P ==>|authorized envelope| G
    G -.->|bound callback / admission receipt| P
    P -->|validated AgentInput| R
    classDef agent fill:#ede9fe,stroke:#7c3aed,color:#2e1065
    classDef gateway fill:#fef3c7,stroke:#d97706,color:#451a03
    style Cognition fill:#faf7fd,stroke:#a78bfa
```

## 文件与职责

| 文件 | 职责 |
| --- | --- |
| [AgentMessaging.swift](AgentMessaging.swift) | AgentMessage 类型擦除／验证、身份绑定传输端口与 DeliveryReport |
| [CommunicationPolicy.swift](CommunicationPolicy.swift) | 契约目录、精确输入／订阅／发布／定向声明及权限判断 |
| [AgentTaskSignal.swift](AgentTaskSignal.swift) | Task 作用域／信封与有界注册表的接纳和状态校验 |
| [DeliveryHistory.swift](DeliveryHistory.swift) | 单传输端口的有界投递结果证据 |
| [SignalObservation.swift](SignalObservation.swift) | Signal 的因果、分支接纳状态、摘要及可选 Task 信封快照 |

## 内部契约

```mermaid
flowchart LR
 D["声明：inputs／subscriptions／publications／sends"]:::host
 P["CommunicationPolicy：来源／目标／权限"]:::host
 S["CommunicationContracts：类型／大小／内容校验"]:::host
 M["AgentMessage：不可变业务内容"]:::host
 T["AgentTaskSignal／Registry：Task 作用域"]:::host
 H["DeliveryHistory／SignalObservation：被动证据"]:::host
 D --> P
 S --> M
 P --> T
 M --> T
 T --> H
 classDef ui fill:#e0f2fe,stroke:#0284c7,color:#0c4a6e
 classDef platform fill:#dcfce7,stroke:#16a34a,color:#14532d
 classDef model fill:#f3e8ff,stroke:#9333ea,color:#581c87
 classDef storage fill:#fef3c7,stroke:#d97706,color:#78350f
 classDef agent fill:#eef2ff,stroke:#6366f1,color:#312e81
 classDef gateway fill:#ffedd5,stroke:#ea580c,color:#7c2d12
 classDef action fill:#ffe4e6,stroke:#e11d48,color:#881337
 classDef host fill:#f1f5f9,stroke:#64748b,color:#334155
```

## 授权与身份

注册契约定义载荷类型和主题，默认主题为契约名。广播订阅精确匹配 contract、source、topic 和 v1 载荷，定向与运行时反馈通过 inputs 接纳。发布者必须有对应 publications，发送权限对应目标 inputs。全局至多 64 个主题，每个主题至多 16 个订阅声明。

因果值保留 incarnation/root/parent/session/turn，最多八跳。Signal 无默认 TTL；显式感知 freshness 由生产者和接收者校验。容器／运行故障由上层直接观察，不在通信注册表发布。

## 投递、任务与完成

send 使用身份绑定输出消费器，选择存活目标并产生关联接纳回执；publish 无回执、无投递历史，即使无订阅者也可完成。发布者校验失败显式返回，订阅者／观察者失败独立记录；不承诺全局 FIFO、exactly-once、自动重试或通用去重。

Task request/input/progress/result/cancel 保存中立作用域与业务 Data，业务最多 65536 字节，编码信封最多 131072；只有 result 表达终态。Registry 最多 256 条记录、16 个非终态后台任务，每任务 128 个已接纳 Signal ID；校验 requester/executor/session/incarnation、重复和终态后输入。满载只淘汰终态，已淘汰身份拒绝迟到报告，迟到接纳不得覆盖真实终态。

Task execution 前台／后台是中立值，反序列化缺少 execution 字段时按 foreground 读入；Core 不加载 Skill。DeliveryHistory 历史最多 128，最旧淘汰计数。SignalTraceRecord 保存因果、摘要及最多 16 个目标分支；Task 消息可附带业务 Data 不超过 64 KiB 的原任务信封，其他消息不保留原始内容。该快照是被动证据，不向发布者确认。AgentMessaging defines cognitive identity-bound messaging ports for Agents adapters and isolated hosts; Gateway SignalTransport exposes its separate generic endpoint API. Production roles emit CommunicationAction.
后台 task.request 可省略业务类型标记。接收角色验证来源、任务授权及载荷。其他任务消息使用自身的类型标记解释内容。
