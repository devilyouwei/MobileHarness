# Signal 核心架构重设计

日期：2026-11-19。状态：非 IPC 代码迁移与工程门禁已完成；真实设备/性能专项待验收，IPC 按用户指定保留为独立待实施范围。实施与验证见第 13 节。本文是 Signal 重设计的需求入口；当前实现以 [总体技术设计](../../../MobileHarness/README.md) 和各模块 README 为准。

## 1. 目标与设计定位

MobileHarness 是 Multi Signal 输入、Multi Action 输出的全双工交互 Agent Harness。Signal 是核心数据交互概念：外部输入形成感知与意图，内部处理形成协作和执行，执行与环境变化继续形成新的 Signal。输入获取与输出执行能够并行，不以等待一轮回复结束作为所有输入的接纳条件。

本次重设计围绕三类边界展开：

1. **外部 Signal**：从 PlatformKit、UI 等输入源直接监听，统一 SignalListener 契约，优先保持低开销和快速获取；消费者可以是 Agent，也可以是直接处理本地交互的 UI。
2. **App 内部 Signal**：通过 Gateway 完成订阅发布、定向投递以及功能调用与反馈，服务 Agent–Agent 和 Agent–Action。
3. **系统进程间 Signal**：通过未来独立设计的 IPC 信道完成 Agent–Program 通信，将任务委派给支持 MobileHarness 协议的系统或第三方 App。

“所有数据处理围绕 Signal”表示统一描述跨边界的数据来源、接纳、处理和反馈；不要求把每个局部变量、模型内部计算、文件字节或同步返回值包装成通用消息。统一概念和可观察契约，不强制统一载荷表示、调度器或物理信道。

## 2. 三类 Signal 分类图

```mermaid
flowchart LR
    S["Signal<br/>MobileHarness 核心交互契约"]
    S --> E["外部 Signal<br/>信道：SignalListener 直接监听<br/>例：传感器多模态数据、点击、状态、数据请求"]
    E --> EM["传感器多模态数据<br/>PlatformKit 硬件抽象 → 感知消费者<br/>已实现：音视频；未来：压力 / 温度等"]
    E --> EU["交互与请求<br/>UI 产生交互 Signal"]
    EU --> UL["浅层调用：UI 内部消费<br/>本地监听 / 原生事件处理<br/>导航 / 双指缩放 / 焦点动效"]
    EU --> UB["业务请求：交给负责的 Agent<br/>SignalListener → Agent → Gateway → Actions<br/>文本提交 / 拍照 / 业务数据请求"]
    E --> ES["状态与事实<br/>能力模块 → 明确的消费者<br/>设备变化 / 运行状态 / 故障"]
    S --> I["App 内部 Signal<br/>信道：Gateway<br/>订阅发布 / 定向递送 / 调用反馈"]
    I --> IA["Agent–Action<br/>单一或组合功能函数<br/>打开相机 / 拍照 / 弹出 Window"]
    I --> IG["Agent–Agent<br/>语义消息与自主 Task<br/>ASR 文本 / 委派 Writer 绘图"]
    S --> P["系统进程间 Signal<br/>信道：IPC，独立设计<br/>尚未实现"]
    P --> IP["Agent–Program<br/>支持协议的外部 App<br/>外部能力 / 跨应用任务 / 进度与结果"]
```

“外部”按输入来源划分：用户交互、硬件感知等来自认知与业务通信之外的输入，不等于来自 App 进程外，也不要求一定进入 Agent。UI 和 PlatformKit 均可在本进程内产生外部 Signal。UI 内部消费用户交互仍属于这一类别，不因消费者在 App 内就变成 Gateway 内部通信。进程间边界单列为第三类。

IPC（Inter-Process Communication，进程间通信）在本文中指待设计的进程间协议与独立信道，不预设具体系统 API。具体平台承载、协议细节和首个对接程序在后续设计中确定。

Action → Agent → Program 表示能力封装与委派范围逐步扩大，不是强制调用层级，也不是按运行时长分类：Action 可以异步，Agent 可以只发轻量消息，Program 也可以提供简单能力。

PlatformKit 在此承担统一硬件能力抽象，概念上类似 Linux `/dev` 将设备能力提供给上层：消费者面向类型化传感器接口，不直接依赖具体硬件驱动。这里借鉴的是设备抽象边界，不要求采用文件节点、字节流或 Linux API。传感器 Signal 可为连续采样、标量读数、向量、帧或离散变化；音视频是当前已实现且数据量较大的子类，压力、温度等是未来扩展，不要求每种传感器都表现为媒体流。

## 3. 当前基线与目标差异

| 范围 | 当前实现 | 本次目标 |
| --- | --- | --- |
| 传感器多模态数据 | 当前主要已实现音视频：SpeechPerception 直接消费 PCM，VisionPerception 直接消费 CameraFrame；不经过 Gateway。压力、温度尚未在本需求中实现 | 面向 PlatformKit 硬件抽象统一监听契约，支持采样、标量、向量、帧和变化事件；保留直接路径，不增加数据转发层 |
| UI 本地交互 | 当前 UI 设计已将纯展示交互保留在 UI；本地导航由 UI Root 拥有 | 将此路径明确命名为“浅层调用”，保留原生事件处理，不为统一 Signal 增加 Agent/Gateway 往返 |
| UI 业务请求、状态与故障 | 通过所属能力的类型化请求、观察、回调接口接入负责角色 | 梳理并统一 SignalListener 接入语义，保留类型与请求完成契约 |
| Agent 通信 | Agents 适配器负责语义与权限，Gateway.SignalTransport 负责进程内递送 | 统一内部 Signal 术语，明确 publish/subscribe、定向 send 的适用范围 |
| 执行调用与反馈 | Gateway 的执行协调设施与 SignalTransport 分工；Actions 执行业务 | 在内部 Signal 模型下解释调用、进度、结果，不把 Action 调用强制改成普通消息发送 |
| 进程间通信 | 当前 SignalTransport 持有进程内载荷和回调，不是 IPC 协议 | 独立设计 IPC 及本地接入适配，不把现有 Swift 对象直接作为跨进程协议 |

基线来源：[直接输入需求及证据范围](Direct-Container-Input-Plan.md)、[业务通信契约](../../../MobileHarness/Agents/Support/Communication/README.md)、[Gateway](../../../MobileHarness/Gateway/README.md)、[SignalTransport](../../../MobileHarness/Gateway/Input/README.md)。历史文档中的契约名不替代当前 [AgentContracts](../../../MobileHarness/Agents/AgentContracts.swift) 和 [角色声明](../../../MobileHarness/Resources/Agents/README.md)。直接输入性能优先是设计目标，尚不能据此声称本次方案已有量化性能提升。

## 4. 计划的生产方、消费方与信道

下表中的统一 SignalListener 和 IPC 均是目标设计；示例角色关系来自现有实现或明确标注的未来接入。

| 类别 / 场景 | 生产方 | 消费方 | 目标通信方式 | 载荷与交付重点 |
| --- | --- | --- | --- | --- |
| 外部：传感器 / 音频（已实现） | PlatformKit.Audio | SpeechPerception | 直接 SignalListener | 原生 PCM；有界、有序、连续性及采集代校验；溢出显式失败 |
| 外部：传感器 / 图像（已实现） | PlatformKit.Vision | VisionPerception；其他显式获准的媒体消费者 | 直接 SignalListener | 原生帧或缓冲引用；最新值策略、新鲜度与所有权 |
| 外部：传感器 / 压力、温度等（未来） | PlatformKit 抽象的内置或外接硬件能力 | 按场景配置的 Perception Agent 或明确获准的消费者，具体角色待定 | 直接 SignalListener | 类型化标量、向量、采样序列或变化事件；声明单位、采样时间、有效性、量程及按需校准信息 |
| 外部：UI 浅层调用 | UI 原生触控、手势、焦点等事件源 | UI 自有组件、导航或交互状态所有者 | UI 本地监听 / 原生事件处理；不经过 Agent、Gateway 或 Actions | 导航、双指缩放、输入框焦点及动效；只改变 UI 所有的局部状态 |
| 外部：用户文本 | UI 会话输入源 | Assistant | 直接 SignalListener 请求 | 文本及请求身份；接纳与回复完成分开 |
| 外部：交互控制 | UI 聆听、相机、相册、设置、窗口输入源 | SpeechPerception、Photographer、ApplicationControl | 直接 SignalListener 请求 | 类型化意图；取消/停止通路；业务结果回执 |
| 外部：状态、环境与故障 | PlatformKit、UI 及拥有事实的模块/容器 | ApplicationControl、Photographer、相关 Agent 或执行所有者 | 直接 SignalListener 观察 | 快照或变化事实；明确初始值、顺序、合并和失败语义 |
| 外部：数据请求 | UI 等调用方 | 按业务归属的 Agent 或已授权的数据能力 | 直接 SignalListener 请求或保留类型化读取接口 | 请求关联、结果类型、失败与取消；订阅不隐含读取或执行授权 |
| 内部：感知语义 | SpeechPerception、VisionPerception | Assistant、Photographer、显式订阅者 | Gateway publish/subscribe | 目标协议 user.input.speech.v1、perception.vision.pose.v1；保留原类型、来源与新鲜度 |
| 内部：任务协作 | Assistant 等获准角色 | Writer 等目标 Agent；回报反向到请求方 | Gateway await send + 授权任务事件订阅 | 提交/补充/取消直接返回 Reply；进度、追问、终态通过任务引用观察；接纳不等于完成 |
| 内部：功能调用 | 发起操作的 Agent | Actions 拥有的功能实现 | Gateway 执行准入与调度 | 打开相机、拍照、展示窗口；执行身份、资源与取消清理 |
| 内部：执行反馈 | Actions 经 Gateway 执行设施 | 原调用所属 Agent | action.result.v1 → signals.feedback | 返回值、异常与原函数/参数快照；不重复执行业务，不保留普通通信回执 |
| 内部：整轮结算 | Agents/Gateway 的可信执行运行时 | 原轮次所属 Agent | agent.round.result.v1 → signals.feedback | 屏障机制保留，结算成功或失败作为独立反馈，不替代单次 ActionResult |
| 内部：打断信号 | 获授权的 Agent/控制来源 | Assistant | Gateway pub/sub：agent.interruption | agent.interruption.v1；发布接纳不等于打断完成 |
| 内部：其他运行时生命周期 | 可信运行时 | 所属执行会话/角色 | 保留内部绑定 | 活动变化与停止清理，不混入 Action 终态 |
| 进程间：外部委派 | MobileHarness Agent，经 IPC 出口适配 | 支持协议的系统或第三方 App | IPC 定向请求 | 能力协商、授权、任务身份、接纳与执行完成分离 |
| 进程间：外部返回 | 外部 App，经 IPC 入口适配 | 原请求 Agent 或明确注册的本地消费者 | IPC 事件 / 进度 / 结果；本地再按政策路由 | 对端身份、版本、断连、迟到、重复与终态校验 |
| 进程间：外部主动事件 | 已授权外部程序，未来按场景开放 | 本地明确允许接收的角色 | IPC 订阅事件，接入后映射本地契约 | 不允许仅凭对端声明冒充本地 Agent、runtime 或用户 |

ModelKit 与 Storage 继续拥有推理和存储能力，不自动成为通用消息发布者。推理结果由调用角色决定是否发布为语义 Signal；存储读取和提交维持类型化接口。确有状态观察需求时，再按外部监听契约暴露。

## 5. 外部信道：SignalListener

### 5.1 统一使用模型

借鉴 JavaScript EventListener 的“输入源注册监听、事件到达后消费、显式移除监听”思路，但使用 Swift 类型化、隔离和异步生命周期契约。SignalListener 是暂定协议族名称；源接口、监听器接口及订阅句柄的最终 Swift 命名和泛型签名待接口设计阶段确定。

概念流程为：`注入源 → listen → 获得订阅句柄 → 消费 Signal → cancel / 结束 → join 清理`。这是设计示意，不是当前可调用 API。

```mermaid
flowchart LR
    App["App<br/>构造与注入"] -.-> Source["输入源<br/>UI / PlatformKit / 能力模块"]
    App -.-> Owner["消费者所有者<br/>UI / Agent / 执行服务"]
    Owner -->|"listen：类型与交付策略"| Source
    Source -->|"直接交付载荷"| Owner
    Owner --> Handle["订阅句柄<br/>取消 / 等待退出"]
    Handle -->|"解除订阅"| Source
```

统一的是订阅与生命周期，不建立全局广播中心，不新增逐帧中转，不强制编码、类型擦除或复制媒体。监听本身不得启动相机/麦克风或隐式获取权限；设备启动仍由明确授权的执行流程负责。

### 5.2 必须声明的契约

| 契约 | 需求 |
| --- | --- |
| 类型与来源 | 源声明稳定类型、设备/传感器身份与来源；支持标量、向量、帧及采样序列。媒体保留原生缓冲及有效生命周期，不统一转为 JSON/Data |
| 传感器测量语义 | 按能力声明单位、量程、采样时间/频率、有效性和按需校准信息；不可用、失效或缺失不伪装成零值。阈值判断等业务含义归消费者 |
| 消费者数量 | 明确单消费者还是多消费者；重复订阅、数量上限及慢消费者处理可测试 |
| 队列与背压 | 每个源明确容量和溢出策略；允许有序 FIFO、最新值替换或拒绝，不设无界默认队列 |
| 隔离与执行 | 明确生产线程/actor 与消费执行域；原生实时回调不能等待任意业务处理；不逐包创建无限 Task |
| 顺序与时效 | 按需保留 sequence、采集时间、generation、新鲜度；不声称跨源全局顺序 |
| 生命周期 | 消费任务由能力或角色所有者持有；取消阻止后续接纳，join 明确等待哪些在途工作；重绑隔离旧代结果 |
| 正常结束与失败 | 区分主动关闭、源正常结束、意外中断、消费错误、容量拒绝；错误传给负责者 |
| 请求与回复 | 请求有 requestID、结果和失败通路；明确仅接纳回执与实际完成，取消请求不伪造业务已撤销 |
| 可观察性 | 提供必要的接纳、处理、替换、拒绝和失败计数；诊断不复制全部原始媒体、不形成第二个积压源 |

连续采样（包括媒体流）、单次读数、离散变化、状态和请求是同一外部类别下的交付模式，不再增加顶层 Signal 类别。状态可选择最新值合并；点击与业务请求不能因此被静默覆盖。请求/响应扩展应按需采用，不为每个音频包生成业务回执。具体容量在逐源清单中确定后才能实施。

### 5.3 UI 内部消费：浅层调用

**浅层调用**指 UI 对交互 Signal 的直接、局部处理：不需要 Agent 理解、决策或 Agent 发起的 Action 控制，就由 UI 的组件或状态所有者完成。可以用“反射式响应”帮助理解其即时、本地闭环的特点；这是设计类比，不表示实现人体反射或自主生理调节机制。

典型场景包括用户点击导航后的本地页面切换、已加载内容的双指缩放/平移、输入框聚焦及焦点动效、按压反馈、滚动和局部展开收起。UI 拥有这些交互状态，事件处理无需等待模型或业务执行。

| 判定 | 处理路径 | 完成边界 |
| --- | --- | --- |
| 只需改变 UI 自有导航、布局、焦点、视口或动效 | UI Signal → 本地处理 → UI 状态/渲染 | 本地状态提交与实际呈现分别确认；不产生虚假的业务完成 |
| 需要理解意图、业务决策、持久化、业务数据查询或设备操作 | UI 类型化请求 → 负责 Agent → Gateway → Actions | 由业务所有者返回实际结果；UI 只处理展示 |
| 同一交互兼有本地响应和业务副作用 | 本地响应立即完成，业务部分另发明确请求 | 两条完成语义分离；导航完成不代表数据已加载或设备已启动 |

例如进入相册的导航可以本地完成，但读取照片记录属于业务请求；缩放已经呈现的图像是浅层调用，控制相机硬件变焦则是设备操作。点击输入框产生焦点与动效可由 UI 消费，提交内容后再按用途交给负责角色。分类依据是状态和效果的所有权，而非“是否点击”“是否执行很快”。

SignalListener 的统一设计应容纳 UI 本地消费，但不要求把 SwiftUI/原生手势回调全部改成异步队列或转发到容器。局部原生处理可直接承载浅层调用语义；只有确有跨组件订阅需要时才暴露监听端口。UI 不依赖 Agents、Gateway 或 Actions 的实现来完成这条路径。

Agent 主动要求导航或展示时，仍走既有 Gateway → Actions → UI 路径；UI 可复用同一状态和呈现能力，不复制第二套状态。UI 本地变化如需供 Agent 感知，应通过已有公开 State 或明确的事实观察提供，不为每次触控强制发送消息，也不把观察回流当作再次执行同一操作的命令。

当前边界依据：[UI 职责与交互路由](../../../MobileHarness/UI/README.md)、[UI Root 导航所有权](../../../MobileHarness/UI/Root/README.md)。

## 6. Gateway 与 Agent Signal 配置：收敛设计

核心约定：**事件按频道订阅；请求按目标直接回复；代码注册能力，JSON 启用接收协议并选择静态事件关系，启动校验完整性，Action 结果与轮次结算以 feedback 独立接纳，任务运行时建立动态观察。**

### 6.1 两种角色通信、独立执行反馈与三个配置归属

| 通信方式 | 寻址 | 完成语义 | 场景 |
| --- | --- | --- | --- |
| pub/sub | channel + 事件协议；订阅用 sources 限定来源，可筛选事件类型 | 发布完成表示 Gateway 已按规则接纳；不代表订阅者业务完成 | ASR、姿态、状态、任务进度与终态观察 |
| send | target + 请求协议 + request | `async throws -> Reply`；回复属于原请求，无独立 response topic 或回执 Signal | 提交任务、补充、答复、查询、取消、短请求问答 |
| feedback | 原调用或轮次的可信 owner/context + 结果协议 | 接纳执行或结算事实；不创建新请求或事件频道 | Action 返回值/异常、整轮结算通知 |

| 配置归属 | 内容 | 不放什么 |
| --- | --- | --- |
| 代码中的能力注册 | 类型化 Request/Reply handler、事件生产/消费能力、版本、大小、交付策略和访问政策 | 不注册没有实现的协议，不复制角色间路由表 |
| Agent.json 的 signals | requests 接收协议启用清单、feedback 执行回报协议，以及静态 publications 与 subscriptions | 不含逐目标 sends/calls、Agent 消息的独立 response/receipt，不含原生监听源或动态任务 ID |
| App 注入的 Gateway 配置 | 中立容量、等待策略、生命周期及诊断上限 | 不包含 Writer/Assistant 业务 schema 或角色业务权限表 |

三类信道边界保持不变：PlatformKit/UI 的 SignalListener 直接监听与 UI 浅层调用不进入此配置；IPC 后续通过独立接入适配，不能直接获得本地 Agent 身份。

```mermaid
flowchart LR
    Code["Agent 代码注册<br/>请求 handler / 事件能力"] --> Assembly["Agents 装配<br/>类型 / 配置 / 政策校验"]
    JSON["Agent.json<br/>signals.requests / feedback / publications / subscriptions"] --> Assembly
    Host["App 宿主<br/>容量与生命周期"] --> G["Gateway"]
    Assembly -->|"中立端点与事件路由"| G
    G --> R["send<br/>目标 + 协议 → Reply"]
    G --> E["pub/sub<br/>频道 + 来源 + 事件"]
    G --> F["执行 feedback<br/>原调用/轮次身份 → 结果"]
    Task["Agents 任务运行时<br/>持久状态 / 参与者 / 游标"] -->|"动态作用域订阅"| G
```

### 6.2 send：所有 Agent 自动接收，handler 决定支持什么

每个已注册的 Agent 都有统一接收入口，不需要配置接收端口开关。具体启用哪些请求协议由 signals.requests 声明；启动时必须验证其静态描述符和 handler 完整。调用未启用或未知协议返回明确的 unsupportedProtocol，而不是超时等待；配置了协议但实现不完整则在启动阶段失败，不能拖到第一次调用。

概念 API（不是当前可编译接口）：

```swift
let reply = try await gateway.send(
    to: .writer,
    using: AgentTask.v1,
    request: .submit(text: goal)
)
```

`AgentTask.v1` 是类型化描述符，示例稳定协议标识为 `agent.task.v1`。描述符绑定 Request、Reply、版本、大小、默认 deadline、操作元数据和访问政策。最终泛型签名在实施前定稿。

角色注册类似 `register(AgentTask.v1, handler: handleTaskRequest)` 的处理器。代码注册定义可实现能力，signals.requests 决定本次启用的协议。协议可跨角色复用；只有完整实现且配置启用、启动校验通过的协议才进入公开自描述和调用目录，不自动把所有角色变为可委派 Agent。配置仅引用协议标识，不复制 Request/Reply schema 或处理逻辑。

接收顺序：活跃目标定位 → 可信来源/代际校验 → 已启用协议及版本查找 → 访问与操作校验 → 类型化 handler → 原调用 Reply/error。未知协议/版本快速失败，不启动模型，不触发业务效果。

- 普通公开协议允许有效本地 Agent 调用，不维护 Assistant→Writer 逐对 send 白名单。
- 任务归属、Skill 与执行授权继续按实际操作校验；受限 handler 显式声明访问政策。支持协议但无权操作返回 unauthorized。
- 同一协议可有明确的操作枚举；例如 AgentTask.v1 的 submit/update/answer/status/cancel。协议描述符声明必需操作与显式可选扩展；必需操作的 handler 必须完整，否则启动失败。可选扩展的支持情况进入自描述，不支持的扩展或未知操作返回 unsupportedOperation；不能把缺失必需操作当作正常运行时拒绝，不靠自由文本建立权限。
- 公开能力目录从已启用且通过校验的 handler 投影，模型是否看到调用工具仍由其有效 Skill/工具目录决定。“所有 Agent 有接收端口”不等于每个模型自动获得所有调用工具。
- 不把内部 runtime/actionResult 等反馈注册成公开 send 协议，避免外部角色伪造执行完成。

Reply 直接沿原调用返回；删除“DeliveryReport 回投 CommunicationReceipt 再唤醒 Agent”的普通通信链。Gateway 内部的调用关联和诊断仍存在，但不再要求接收者发送另一条回复消息或调用者订阅回执。

### 6.3 pub/sub：频道有协议，订阅有来源

事件地址由 `channel + source` 标识；单条 Signal 的 source 仍是一个可信生产者，配置的 sources 是允许匹配的来源集合，channel 绑定一个带版本的事件协议。协议可以是枚举，如 user.input.speech.v1 中的 partial/final；订阅通过 events 选择变体。channel 是逻辑事件流，protocol 是数据契约，两者不互相隐式推导。

```swift
try await gateway.publish(channel: .userSpeechInput, event: SpeechInput.final(text))
```

发布端口在装配时绑定真实生产者，调用者不能填写任意 source。静态订阅由 JSON 装配到已注册的类型化消费者，业务代码无需再重复 subscribe 一次。运行时动态任务观察复用相同递送机制，但不写入 JSON。

统一使用 **EventChannel** 表示事件频道，既有 Action 的排序 Channel 保留执行域语义；两者不能共用一张配置表或以同名值暗中耦合。

交付规则由事件协议的类型化描述符定义，JSON 不配置并发或队列：

- 姿态、partial 等可采用显式 latest-value 合并；final、任务追问/终态不能因共用频道而被覆盖。按事件变体定义策略，不对整个频道套一个粗粒度丢弃规则。
- 在源作用域内保留序号；每个订阅消费有确定顺序。不同来源没有全局顺序承诺；晚订阅不默认重放普通事件。
- 发布先验证自身类型、来源及全局预算；失败时不发出任何分支。发布已接纳后，各订阅分支独立处理容量和消费者失败，记录明确的 accepted/coalesced/rejected/closed 证据；不引入跨消费者原子事务，慢诊断观察者不能阻塞其他角色。不可丢弃事件拒绝必须通知负责者，不能静默吞掉。不得因一个分支失败重发整个广播，造成其他分支重复；可靠性由目标业务处理，任务事件使用持久恢复。
- 无订阅者可以正常发布，诊断标为 unobserved；发布成功不表示有人接收，更不表示业务完成。
- 任务的可靠恢复由任务持久状态与游标负责，不让通用 pub/sub 承诺持久递送。

#### 打断：授权来源发布，Assistant 订阅

打断采用 pub/sub，Channel 为 agent.interruption，Protocol 为 agent.interruption.v1。多个获授权 Agent 可发布，Assistant 用一条订阅的 sources 显式列出接收来源；不在 requests 中启用同名 send 协议，不重复建立两条外部打断路径。

载荷保留 signalID、会话作用域、目标 current/replyID 及可选原因。对于 current，Assistant 在实际接收时锁定同会话当前回复；replyID 只匹配已捕获的回复。可信来源由发布端口绑定，Assistant 检查作用域、来源政策与目标有效性，去重后调用现有 requestInterrupt，清理加入后才记录处理完成。信号在控制路径处理，不排入普通用户文本队列，也不再次调用 Decision。

publish 只表示发布接纳，不表示 interrupted。处理结果保留内部事实/诊断，不自动新增 response 频道；若后续业务明确需要发布方观察完成结果，再单独定义观察契约。控制信号不可静默丢失或被普通进度合并；容量拒绝显式报告，端点更替和迟到目标拒绝，不自动重放到下一条回复。中断分支必须有独立控制准入，不能被普通事件等待队列耗尽；具体全局槽与字节预留在第 11 节实施门槛中确定。

Assistant 内部 Decision、可信宿主控制继续直接调用同一处理入口，不为复用协议强制绕 Gateway。非 Agent 来源若需通过 Gateway 发布，必须由 App 注册中立可信来源并赋予指定频道的发布能力；UI/PlatformKit 不直接取得 Agent 通信权限。此次配置示例不引入任意来源或通配来源。

#### Channel 与 Protocol 的分层命名规范

二者都按**语义域 → 能力/对象 → 具体语义**从大到小命名，但含义不同：Channel 标识事件流，Protocol 标识类型与行为契约。域名描述业务语义，不直接复制源码目录、生产者类名或传输方式。

| 标识 | 格式 | 示例 |
| --- | --- | --- |
| EventChannel | `<domain>.<subject>[.<stream>]`，必要时增加语义层级 | user.input.speech、perception.vision.pose、agent.task |
| Protocol | `<domain>.<subject>[.<contract>].v<major>` | user.input.speech.v1、agent.task.v1、agent.task.events.v1、action.result.v1 |
| 事件变体 | 协议枚举成员，独立放在 events/payload | partial、final，不作为请求/回复 topic |
| 来源与作用域 | 独立的 source/target/scope 字段 | speechPerception、writer、taskRef，不拼进频道或协议名 |

首批语义域固定为 user（用户意图/输入）、perception（加工后的感知事实）、agent（角色协作）、action（功能执行）。新增域需有真实语义边界，不能为每个 Agent 或设备建一个域。原始压力、温度、PCM 等仍走 SignalListener，不因制定 Channel 规范就迁入 Gateway；以后若发布加工后的感知事实，再定义 perception 下的业务契约。

具体命名表：

| 用途 | Channel | Protocol | 进一步区分 |
| --- | --- | --- | --- |
| 用户语音识别输入 | user.input.speech | user.input.speech.v1 | events=partial/final，sources=[speechPerception] |
| 姿态感知 | perception.vision.pose | perception.vision.pose.v1 | sources=[visionPerception] |
| 声源感知 | perception.audio.source | perception.audio.source.v1 | 声源类型与测量内容在载荷中 |
| 打断信号 | agent.interruption | agent.interruption.v1 | 授权来源发布，Assistant 订阅；载荷区分 current/reply 与会话 |
| 任务请求 | 无，send 指定 target | agent.task.v1 | submit/update/answer/status/cancel 在请求操作枚举中 |
| 任务后续事实 | agent.task | agent.task.events.v1 | scope 区分实例，事件枚举区分进度/追问/终态 |
| Action 调用 | 无事件频道，保留独立执行 Channel | action.invocation.v1 | function 区分具体功能 |
| Action 回报 | 无，按 owner 定向 feedback | action.result.v1 | function/callID 区分具体调用 |
| 整轮结算回报 | 无，按轮次 owner 定向 feedback | agent.round.result.v1 | roundID 区分轮次，屏障后回报完成或失败 |

命名与校验规则：

- 点号分层，使用小写 ASCII 单词和数字；每段以字母开头，协议最后一段固定为 v 加正整数。使用 `^[a-z][a-z0-9]*$` 校验普通段，版本段为 `^v[1-9][0-9]*$`。不混用大写、下划线、连字符、斜杠或空段。
- Channel 为 2–5 个语义段；Protocol 为 2–5 个语义段加 1 个版本段；各完整标识最多 64 UTF-8 字节。层数用于限制过度细分，不要求所有名称补齐到同一深度。
- Channel 不带协议版本，不含 Agent ID、会话/任务/设备实例 ID、时间或 UUID。需要并行运行不兼容版本时，另行设计显式兼容绑定/迁移方案；首版仍执行一个频道绑定一种协议的约束，不临时拼接 `.v2` 成频道。
- Protocol 的主版本标识固定完整契约。兼容新增字段必须声明默认值/可选规则并验证旧消费者；破坏性变更升主版本。配置 schema 的 version 与协议版本互不替代。
- 相同前缀便于理解，不建立隐式路由：channel 与 protocol 仍显式绑定；send/feedback 的协议不因名称有点号就产生频道。禁止通配、前缀继承和自动订阅子频道，例如订阅 perception 不代表订阅其下所有事件。
- 同一概念只保留一种稳定名称；不并存 speech/asr/transcript 三种同义频道。名称不编码 handler 所在模块；以后替换发布者由 source 和装配决定。
- 现有执行 Channel（例如 Speech/Control）和 canonical 函数地址（例如 Camera.Capture.takePhoto）属于另一套既有命名体系，本次不改名，也不把它们按事件频道规则校验。现有 lowerCamelCase Agent ID 同样保留。
- 所有示例新名称均属待实施方案。启动校验标识语法、描述符存在与绑定一致性；旧契约/频道必须显式迁移，历史记录保留原名，不按新规范重写历史事实。

### 6.4 Agent.json：请求、执行反馈与静态事件关系

拟议资源 schema 从 v10 升到 **v11**，将 communication 替换为 signals。以下是新设计示例，不能直接替换当前资源并期待旧加载器接受。其他字段保持现有职责，示例 description 可保留角色现有完整文案。

Assistant：

```json
{
  "version": 11,
  "id": "assistant",
  "category": "cognition",
  "description": "Handle user conversation and coordinate available capabilities.",
  "baseSkills": ["basic-skill", "expression-interaction"],
  "signals": {
    "requests": [],
    "feedback": ["action.result.v1", "agent.round.result.v1"],
    "publications": [],
    "subscriptions": [
      {
        "channel": "user.input.speech",
        "protocol": "user.input.speech.v1",
        "sources": ["speechPerception"],
        "events": ["final"]
      },
      {
        "channel": "agent.interruption",
        "protocol": "agent.interruption.v1",
        "sources": ["applicationControl"]
      }
    ]
  }
}
```

Writer：

```json
{
  "version": 11,
  "id": "writer",
  "category": "cognition",
  "description": "Own background creative tasks and their results.",
  "baseSkills": ["writer-workspace"],
  "signals": {
    "requests": ["agent.task.v1"],
    "feedback": ["action.result.v1"],
    "publications": [],
    "subscriptions": []
  }
}
```

Writer 的 requests 显式启用 agent.task.v1，代码提供完整 handler；publications/subscriptions 的空数组仅表示没有静态事件关系。任务运行时按已接纳工作创建受控事件源，Assistant 自动观察自己的委托，不需要固定 writer→assistant 消息白名单。Assistant 订阅 agent.interruption / agent.interruption.v1 以保留打断接收能力，并启用 agent.round.result.v1 以接收轮次结算；其向 Writer 发起 send 或收到原调用 Reply 不依赖 requests：该字段只配置入站请求协议，不是发送许可。其他角色示例暂不列固定任务协议，只说明格式，不授权删除现有固定任务能力；最终启用清单必须按第 6.10 节逐角色盘点。

SpeechPerception：

```json
{
  "version": 11,
  "id": "speechPerception",
  "category": "perception",
  "description": "Interpret microphone input and publish speech and sound-source observations.",
  "baseSkills": [],
  "signals": {
    "requests": [],
    "feedback": ["action.result.v1"],
    "publications": [
      {"channel": "user.input.speech", "protocol": "user.input.speech.v1"},
      {"channel": "perception.audio.source", "protocol": "perception.audio.source.v1"}
    ],
    "subscriptions": []
  }
}
```

其他角色的 signals 对象示例：

```json
{
  "applicationControl": {
    "requests": [],
    "feedback": ["action.result.v1"],
    "publications": [{"channel": "agent.interruption", "protocol": "agent.interruption.v1"}],
    "subscriptions": []
  },
  "visionPerception": {
    "requests": [],
    "feedback": ["action.result.v1"],
    "publications": [{"channel": "perception.vision.pose", "protocol": "perception.vision.pose.v1"}],
    "subscriptions": []
  },
  "photographer": {
    "requests": [],
    "feedback": ["action.result.v1"],
    "publications": [],
    "subscriptions": [
      {"channel": "perception.vision.pose", "protocol": "perception.vision.pose.v1", "sources": ["visionPerception"]}
    ]
  }
}
```

Assistant 示例中的 applicationControl 是拟议授权发布来源示例，不表示当前代码已接通该广播。上述多角色示例给出配套 publication；采用此配置时，该来源还必须实现匹配的发布能力；也可在 sources 中列出多个明确授权的来源。完整来源清单随实际业务装配确定，不能只新增订阅而缺少发布实现。其他按轮次结算的角色也必须按自身执行绑定启用 agent.round.result.v1，不只限于 Assistant。

上面的多角色对象只是文档对照，不新增集中式角色配置文件。每个 signals 对象仍放回其所属 Agent.json。

字段规则：

| 字段 | 规则 |
| --- | --- |
| signals | 必填；只接受 requests/feedback/publications/subscriptions，四数组必填，空值为 [] |
| requests[] | 本角色启用的入站 Request/Reply 协议标识；无重复、最多 32 项；必须匹配完整静态描述符和 handler。空数组表示不开放业务请求协议，统一接收入口仍返回明确的不支持错误 |
| feedback[] | 启用的执行回报协议标识，当前规划 action.result.v1 与 agent.round.result.v1；无重复、最多 16 项；必须存在静态描述符和完整接收 handler。无需 source/target/channel，Gateway 从原调用或轮次绑定身份。空数组表示不接纳此类 Agent 反馈，不允许把需要反馈的调用配置成静默丢失 |
| publications[].channel / protocol | 必填；本角色必须注册匹配的事件生产能力；不写 source，运行时绑定本角色 |
| subscriptions[].channel / protocol / sources | 必填；sources 为非空、无重复的显式来源 ID 数组，最多 16 项；每个来源须有匹配 publication 或宿主注册的授权发布能力。运行时暂未启动可等待重新绑定，不启动发布者 |
| subscriptions[].events | 可选，省略表示协议内全部事件；出现则必须是非空、无重复的已知事件集合 |
| protocol | 示例使用带版本的稳定标识，不再同时填写 version/kind/contract/topic；schema version 仍独立 |

发布者与消费者代码声明“具备什么能力”，JSON 声明“本角色启用哪些请求/执行回报协议、接通哪些静态事件关系”。这种分工允许调整订阅而不复制类型定义；配置不能凭空制造生产者或 handler。配置统一使用 sources 数组，单来源也写一项，不同时接受 source 字符串与 sources 两种格式。首版不支持通配 sources、正则 channel 或热更新，避免引入隐式路由和复杂重绑政策。

装配时按命名规范校验标识，并校验未知字段、重复/重叠订阅、频道协议冲突、源不存在、无对应生产/消费能力及容量，错误明确失败。同一 channel 在当前 App 目录内只绑定一个 protocol 标识；不兼容协议迁移必须显式替换或使用新频道，不能混发两种 schema。source incarnation 由生命周期运行时绑定，JSON 不保存实例身份。

#### 启动协议完整性校验

启动采用“加载 → 校验 → 绑定 → 开放准入”，在完整校验前不允许请求进入。能力描述符的检查是静态装配，不启动模型、相机或真实业务工作。feedback 与 requests 同样校验协议存在、版本、完整 handler 和类型；需要结果反馈的角色/执行绑定若未启用相应 feedback，则报启动协议异常。动态启用的新执行能力在准入时也要检查结果接收能力，不能执行后才发现结果无人消费。

| 情况 | 启动/运行行为 |
| --- | --- |
| 配置启用，描述符与 handler 完整且版本匹配 | 启动绑定端点，协议进入有效能力目录 |
| 配置启用，但描述符未知、缺少 handler、必需操作缺失或 Request/Reply 类型不匹配 | 抛出结构化启动协议异常，关闭该次根启动准入，不静默跳过 |
| 已实现但未配置启用 | 正常启动；该协议不绑定、不出现在有效目录，调用返回 unsupportedProtocol |
| requests 为空 | 正常启动；接收端口存在，不开放业务请求协议 |
| 已声明必需的角色能力/组合依赖未启用 | 启动校验失败；不要求把所有可选实现都启用 |
| 外部请求使用未知或未启用协议 | 运行时明确拒绝；不是启动异常 |

异常建议统一为 AgentProtocolStartupError，携带 agentID、配置字段路径、protocolID、期望/实际版本和具体原因，如 unknownProtocol、missingHandler、missingRequiredOperation、schemaMismatch、duplicateHandler、missingRequiredProtocol。只列出本次启用清单和显式必需依赖的问题，不把未启用的可选实现误报为缺失。

必需操作集由协议描述符拥有；具体角色若只提供较小功能，应实现适合的协议或已声明的可选扩展，不能声称完整支持却缺少必需操作。静态校验可证明注册完整性和类型匹配，不能证明真实业务正确，仍需行为测试。

全体配置与实现校验通过后再发布有效目录并开放根准入。静态完整性通过角色工厂/类型化注册清单验证；不为检查 handler 而创建模型会话、激活设备或启动按需角色。实际角色实例创建时才绑定活跃端点，并复核与已验证清单一致；具备静态实现但当前未启动仍返回 unavailableTarget，不能误报 unsupportedProtocol。绑定阶段失败时撤销本次部分绑定、加入清理并报告启动失败；不留下“部分已启用但 App 宣称启动成功”的状态。该失败范围沿用 App 组合根启动/回滚契约。运行中设备或模型暂不可用仍是运行时能力故障，不混入静态协议完整性异常。

首版不热更新协议启用清单；变更配置需要受控重建或重启并重新校验。启动时不要求其他可选角色实例一直运行，静态能力存在与当前端点在线分别判断。模型可见协议目录只能投影最终启用集合，不能直接暴露全部注册实现。

### 6.5 长期任务：send 接纳，任务层自动观察

长期任务不是一次请求长期占用的通信槽。任务层提供“提交并观察”便利入口，内部仍只有 send 与 pub/sub 两种原语：

```swift
let submission = try await tasks.submit(to: .writer, text: goal)
// submission 保存可查询的消息/任务引用；观察由 Agent 所有者持有。
```

这一调用取得真实接纳后返回，并由角色所有的任务协调器建立、消费和清理观察；不把每次任务的 channel/source/event 配置暴露给模型或 Agent.json。

```mermaid
sequenceDiagram
    participant A as Assistant 任务协调器
    participant G as Gateway
    participant W as Writer
    participant S as 任务持久状态
    A->>G: await send(writer, agent.task.v1, submit)
    G->>W: 认证请求
    W->>S: 持久接纳消息，保存可查询引用
    W-->>G: Reply accepted(reference) 或 rejected(reason)
    G-->>A: 直接返回 Reply
    A->>G: 任务层以引用绑定受控观察
    G->>W: 校验参与者，取得快照与事件游标
    W-->>G: 快照与可恢复游标
    G-->>A: 建立任务事件观察
    W->>G: 持续发布任务事实
    G-->>A: 状态 / 追问 / 终态
    Note over A,W: 原 send 已结束；Writer 与 Assistant 独立运行
```

图中观察绑定是任务层流程，由受控 send 与订阅组合实现；也可在提交 Reply 携带快照/游标以减少往返。两种实现都必须保证接纳与观察之间已经发生的终态不丢失。

Writer 可能先收下消息，再用自己的模型决定新建/补充/拒绝。因此 Reply 可以是 accepted(messageRef, taskRef?)、已处理结果或明确拒绝，不伪造“已开始执行”。messageRef 作为稳定观察起点，后续任务归属由 Writer 持久建立。

动态事件地址采用结构化 `(channel: agent.task, scope: messageRef/taskRef, source: executor)`，事件协议为 agent.task.events.v1。不拼接 request/response topic；scope 不改变 channel 的类型。只有认证参与者可观察，引用不是任意操作权限。任务控制仍通过 send，任务事件只表达事实，不把观察者变为执行者。

持久状态和通知由 Agents 任务所有者通过 Storage 管理，Gateway 保持内存递送职责：

- 快照与事件游标原子接续，或先订阅再按版本对账；终态早于订阅也能取回。
- 普通进度可合并；追问与终态保存可恢复证据。新会话根据已持久关联恢复未消费通知，消费标记与业务视图提交保持一致，不把模型是否播报当作消费确认。
- 正常断开观察只释放订阅，不取消后台任务。显式取消使用 send，只有真实清理后才确认取消完成。
- 可选 `await task.result()` 复用任务观察，不新增 Gateway 通信机制，不占用最初 send 的槽。
- Writer 的持久 outbox 在新恢复机制通过验证前保留；不能用不可靠广播替换它，也不双发新旧通知。

### 6.6 生命周期、故障与容量

请求/回复独立于 Agent 普通输入队列。回复直接恢复调用者，不需要同一串行 inbox 再消费 receipt；等待期间控制/取消请求仍有处理机会。调用链保留因果身份并拒绝循环等待；不得在持有不可重入业务锁时等待其他角色回调。

send 至多完成一次；可信运行时绑定 requestID、source、target incarnation 与 deadline。未知端点、未知协议、版本/操作不支持、未授权、无效载荷、容量满、关闭分别可辨。业务拒绝由 Reply 表达；执行异常保留结构化错误。

超时/取消只结束当前等待，已经接纳的任务不自动撤销。可能已发生效果时保留 requestID 与 outcomeUnknown，支持按稳定身份查询；不自动重试有副作用请求。显式重试由任务层幂等接纳，不承诺通用 exactly-once。过期或迟到回复不完成新调用。

等待槽可释放，但仍未退出的处理器必须由目标所有者持有并计入在途预算直到 join；不能在超时后无限启动替代任务。目标退役关闭准入、结束等待、取消并加入所拥有处理器；后台业务任务按自身生命周期处理，不能把端口关闭等同于业务清理成功。

初始容量预算如下，属待验证的设计值，不是当前性能结论；App 可降低，提升需重新验证：

| 资源 | 初始界限及满载策略 |
| --- | --- |
| 注册端点 / 协议目录 | 128 个端点；请求、事件与执行反馈描述符合计 128 项；超限装配/注册拒绝 |
| 静态频道与角色关系 | 64 个频道；每角色 64 项 publication、16 项 subscription；每频道最多 16 个静态订阅；每订阅 sources 至多 16 项；重复与重叠拒绝 |
| 活跃 send | 全局 128，每目标 16；每目标其中 1 槽保留给协议声明且已授权的取消/控制操作；非控制最多 15，无额外等待队列 |
| 消息预算 | send 与事件设施共享 8 MiB 在途逻辑载荷预算；请求/回复各最多 256 KiB，协议可更小；接受请求时预留回复上限，回复不争用新的普通投递槽 |
| 事件分支 | 全局至多 256 个在途/待处理分支；每订阅 16 个等待事件加 1 个处理事件；按协议变体合并或显式拒绝该分支，不无限阻塞生产者 |
| 动态任务观察 | 全局 128 个观察，每个任务作用域至多 16 个观察者；与事件分支及字节预算共同约束；满时显式拒绝观察并保留持久可查询状态 |

上表 send/事件字节限额不直接套到已有 Action 返回值上；执行反馈继续使用原结果账本的容量及业务结果约束，不截断或静默拒绝实际返回值。静态与动态订阅有独立数量账本，共用递送预算。诊断沿用有界记录策略，不保留全部原始载荷。协议级默认 deadline 为必填有限值，由 handler 设计时确定；调用者只能缩短。任务长期运行不使用无限 send deadline。共享预算中的取消准入与回复保留需要在实现前验证资源预留算法，不能仅靠声明有“控制槽”保证字节满载时可取消。

### 6.7 Agent–Action：统一调用契约与独立结果反馈

#### 命名依据与决定

ReAct 原论文使用 **Observation** 表示行动后获得的观测，示例轨迹交替出现 Thought、Action、Observation；作者介绍也以环境 feedback 描述这些信息的作用。来源：[ReAct 原论文，§2 与附录示例](https://ysymyth.github.io/papers/react_llm.pdf)、[作者团队的 Google Research 介绍](https://research.google/blog/react-synergizing-reasoning-and-acting-in-language-models/)。论文给出了推理/行动术语，不规定软件配置字段名。

本项目选择 **signals.feedback** 作为独立配置字段，具体回报协议命名 **action.result.v1**、类型概念为 **ActionResult**。原因是此处需要区分“执行产生的回报”与原始传感器观察、普通事件订阅；Observation 在本项目会覆盖更广泛的输入含义。ActionResult 被 Agent 转为模型上下文时可以作为 ReAct Observation。Feedback 是工程职责名，Result 是具体载荷，Observation 是认知使用方式，不将三者再拆成三份消息。

feedback 不是评价分数或用户点赞，也不是新请求：接纳原调用或轮次关联的真实返回值、异常及结算事实。与 Agent–Agent 的 send Reply 不同，它保留现有异步 Action 调度后的定向回报语义；不改成 pub/sub，不增加 action.result 订阅频道或通用通信回执。

#### 当前调用与优化范围

当前 AgentOutput 分为 ActionCall（actionPath/channel/parameters）与 ToolCall（id/toolPath/arguments），由 OutputEnvelope 携带来源、会话、输入、轮次和因果信息。中立执行侧已有 FunctionRequest、FunctionInvocation，排队侧另有 ScheduledAction。Gateway 通过 ActionsExecutionPort 的 prepare/execute/discard 调用 Actions；函数目录由 catalog 提供。源码见 [AgentOutput](../../../MobileHarness/Agents/Support/Core/Output/AgentOutput.swift)、[FunctionRequest](../../../MobileHarness/Actions/Support/Contracts/FunctionRequest.swift)、[ActionsExecutionPort](../../../MobileHarness/Actions/Support/Contracts/ActionsExecutionPort.swift)。

选定的优化是统一调用与结果的字段、身份和版本契约，保留排队与直接执行设施：

| 方向 | 契约 | 入口/递送 |
| --- | --- | --- |
| Agent → Action | action.invocation.v1 / ActionInvocation | 原 Gateway 执行入口；按既有可信绑定排队或直接调用，不经 Agent send |
| Action → Agent | action.result.v1 / ActionResult | Gateway 从执行结果构造反馈，按原 owner 定向交付已启用的 feedback handler |

这是一对执行契约，不是 request topic / response topic。协议标识描述进程内类型化 schema，不要求 JSON 编码或新增消息跳转。Action 不变成消息接收 Agent，不新增请求监听器、Execution 句柄或 execute/send 新 API。现有 Actions/Support 已有 ActionInvocation 类型，实施时应复用/协调既有命名与中立契约，不再创建平行同名结构。

模型 Action/Tool 调用格式继续作为入口适配。两者共用规范化函数地址、参数和调用身份，再交给原调度/直接执行路径。执行 Channel、资源和权限来自可信绑定，不成为模型可自由填写的信道参数。当前按 ActionCall/ToolCall 入口分派的行为先保持，executionPolicy 是否成为唯一分派依据不在本轮修改范围。

#### 统一的调用关联

| 字段组 | 契约 |
| --- | --- |
| protocol | action.invocation.v1；和结果 schema 的兼容关系由静态执行契约声明 |
| callID | 每次规范化调用必有稳定 ID；保留模型原生调用关联，可信运行时保证作用域内唯一 |
| function / arguments | 必填的不可变调用快照：canonical ActionIdentifier（完整函数名）及本次传入的每个参数名和对应值；复用现有参数校验，本轮不改参数编码体系 |
| owner / context | 可信运行时绑定 Agent/端点、incarnation、session、input 及可选 round/task/turn；调用者不能靠 payload 授权 |
| executionID | 实际执行实例身份，由执行运行时分配；与 callID 关联，不取代它 |
| scheduling | 单独保留已有 Channel/ordering scope/wait 等执行元数据；不复制到业务参数 |

Gateway 各适配层传递同一身份，不反复推断来源。调用在执行前被拒绝时也保留 callID；没有真实执行则 executionID 可空、effect 为 notStarted，不能伪造执行成功。排队、准备、执行和结果递送维持各自阶段。

#### ActionResult：返回值与异常的统一表达

| 字段 | 含义 |
| --- | --- |
| protocol | action.result.v1 |
| callID / executionID | 对应原调用及实际执行；迟到、重投与接收去重的关联依据 |
| function | 从 Invocation 保留的 canonical 函数路径（完整函数名） |
| completedAt | 实际终态的发生时间，重投不改写；接收时间另记，供 Assistant 多源时间线正确排序 |
| arguments | 从同次 Invocation 保留的完整输入参数名—值快照；不是返回值，也不是处理完成后读取的当前配置 |
| owner / context | 从原调用保留，不由 Action 选择目标 Agent |
| status | succeeded / failed / partialFailure / cancelled，复用实际终态 |
| completion | completed（无业务返回值）、value、report、activityStarted/activityStopped 等既有完成值；不能把空字符串等同无返回值 |
| failure | 结构化 code、message、必要的 cause/report；保留超时、业务异常和清理失败，不压缩为泛化字符串 |
| effect | notStarted / contractCompleted / unknown，区别是否已产生效果以及确定性 |

成功必须有合法完成证据；失败可携带实际部分效果，但不能把它解释为成功。取消和异常不能覆盖已经发生的真实部分失败。启动录像的完成只证明开始动作满足契约，不证明录像已经结束。ActivityEvent 保留内部生命周期绑定；roundResult 迁为独立 agent.round.result.v1 feedback，两者均不混入单次 ActionResult。

具体字段优先复用现有中立 ExecutionResult、ActionCompletion/ActionReport/ActionFailure 和认知侧 ActionResult/ToolResult。统一的是终态事实及关联协议；模型原生 tool-call 的结果格式仍由适配器生成，不要求把所有结果强制转字符串或 JSON。

#### 调用参数快照：Invocation 与 Result 对齐

- 在调用入口完成函数地址解析后冻结传入参数快照，Gateway 随执行记录保留，生成 Result 时直接复用。不能从当前 UI、模型上下文或可能已变化的设置重建，也不由 Action 在结束时自行重新填写。
- arguments 保存实际传入的参数名及值，区分缺省、空字符串、零和 false；本轮沿用现有字符串参数表示，不把字符串伪装成已升级的类型化值。无参数调用显式记录空参数集合。
- 如果执行端根据配置解析缺省值或进行单位换算，原 arguments 不被覆盖；确需回报实际解析值时，在执行报告中明确标注 resolvedArguments 及其产生阶段，不能冒充调用方原始输入。
- 成功、异常、部分失败、取消及执行前拒绝均保留已有调用快照。尚未成功解析函数名或参数的解析错误保留原入口错误证据，不制造合法的 Invocation。
- 返回值继续放在 completion/value，输入值放在 arguments；二者不能共用一个模糊 value 字段。重投同一结果必须保持同一输入快照。
- 进程内可共享不可变快照，避免每次投递复制整份参数；结果在持久记录或导出时须具有可恢复的输入内容，不能仅引用已释放的内存。参数快照计入相应记录容量，不在执行后因诊断限制静默截断。
- 沿用现有敏感字段边界：可信执行保留所需输入，模型/诊断/持久化投影不暴露密钥等秘密；脱敏必须显式标记，不把脱敏文本标为原始值。原生媒体附件和凭据句柄不被展开到普通参数日志，保留受控引用及必要元数据。

例如调用 Camera.Capture.takePhoto，传入 delaySeconds="3"，其成功结果或相机不可用异常都携带相同的函数名与 arguments={delaySeconds: "3"}；之后界面改成其他倒计时值不影响该记录。此例是协议字段示意，不是已执行的设备测试。

#### 回报路径与消费语义

```mermaid
sequenceDiagram
    participant A as 发起 Agent
    participant G as Gateway 执行设施
    participant X as Actions 功能
    participant H as 原 Agent feedback handler
    A->>G: action.invocation.v1，经既有执行入口
    G->>X: 原 prepare / 排队或直接执行 / execute
    X-->>G: 完成值或异常，保留部分效果
    G->>H: action.result.v1，绑定原调用 owner
    H->>H: 校验关联，去重，接纳执行事实
    H-->>G: 内部接纳状态，不生成 Reply Signal
    H->>A: 按角色策略更新上下文或进入 ReAct
```

- Action 只返回结果或抛出异常，不认识 Assistant、不发布消息、不选择接收者。Gateway 负责执行事实与原调用身份关联，Agents 适配器负责认知侧格式与接收绑定。
- feedback 只能由可信执行链递送，不能通过普通 send、pub/sub 或自由填入 runtime 来源伪造；接收者核对 call、owner、incarnation、会话及终态。
- Gateway 复用现有有界结果账本、容量预留及取消/关闭语义；接纳成功、暂时繁忙、作用域关闭分别处理。重试只重投不可变结果，不重新执行功能。结果递送失败必须留下关联证据，不伪造接收成功。
- 接收去重与事实提交形成一个受保护的接纳步骤；失败不能提前记为已消费。已接纳结果再次送达仅确认已有事实，不重复入 ReAct。
- scheduled Action 沿当前账本回报；直接 Tool 保留原返回链，在已有结果适配边界形成同一 ActionResult 事实。每次调用绑定唯一的认知消费入口，不能让直接返回和额外 Signal 各自推进一次 ReAct。无需绕路再经过普通消息队列。
- handler 负责接纳与关联，不必须立即执行一次模型请求。成功无返回值、业务值、异常按角色政策处理；全双工的现有输入协调和轮次结算继续负责何时 ReAct。
- feedback=[] 不意味着执行失败可以丢弃。需要认知回报的能力必须启用对应协议；不需要模型反馈的本地执行仍通过原调用返回/运行时诊断处理失败。静态依赖启动检查，动态能力准入检查。

feedback 的配置与启动校验统一见第 6.4 节；同时校验调用/结果版本兼容性与执行绑定依赖。启用 feedback 不授予函数执行权限，函数可用性由 Skill/内部绑定决定。反馈端口须在执行准入前建立，关闭时先排空或明确终结对应执行与结果投递。

#### 整轮结算：agent.round.result.v1 feedback

将现有 roundResult 的**通知**归入 signals.feedback，协议为 agent.round.result.v1，不设置 EventChannel。命名按 agent（语义域）→ round（对象）→ result（契约）→ v1（主版本），与 action.result.v1 的单调用粒度区分。

原屏障仍是：roundFinished 封口 → 加入该轮所需执行/清理与结果递送 → 产生轮次结果。不是将屏障本身改成异步事件，也不能在模型输出结束时就报告结算成功。

| 字段 | 契约 |
| --- | --- |
| protocol | agent.round.result.v1 |
| roundID / owner / context | 可信运行时保留所属轮次、Agent 实例、会话及输入关联；不接受普通 send/pub/sub 伪造 |
| status / failure | settled 或 failed，失败保留结算/递送/清理错误；settled 表示结算完成，不表示所有 Action 业务成功 |
| settledAt | 本次结算通知产生的时间，重投保持不变 |

单次 Action 异常由 action.result.v1 表达；所有必需结果均已接纳、清理完成而其中某个业务调用失败，仍可正常 settled。结果未能送达、清理/屏障失败时回报 failed，不能把业务失败和结算失败混为一谈。

Agent 为该轮保留结果接纳状态，确认所需 Action/Tool 反馈已处理后，轮次 feedback 才解除下一批输入的结算等待。Gateway/执行运行时必须先完成既有结果递送屏障，再产生轮次通知；重复 roundID 通知不得二次推进，旧实例/已关闭轮次不得唤醒新轮。异常关闭也必须结束等待并留证，不依赖一条已无法递送的反馈永久挂起。

调用输出、单调用结果和轮次结算保持各自关联，不在轮次结果中复制所有函数及参数快照；这些证据由同轮 action.result 记录拥有。原生 Tool 配对、Action 排序与 wait 语义均保持。

### 6.8 现有契约与配置迁移

当前 send 实际按 target + contract 路由；task.request 是协议名而非订阅 topic。但 CommunicationContract 默认生成 topic，普通 send 返回 DeliveryReport，CommunicationAction 再回投 runtime.message.receipt，业务结果又另发 agent.task.response。新设计针对这几个混合点简化。

| 当前项 | 新设计 |
| --- | --- |
| communication.inputs / sends | 删除逐目标发送权限与混合输入声明；入站请求协议改为 signals.requests，启动核对完整 handler；业务政策独立 |
| communication.publications / subscriptions | 改为 signals 下明确 channel/protocol/sources/events 的静态关系 |
| contract 默认同名 topic | 删除默认耦合；只有事件描述符与频道绑定，不给 send 附带 topic |
| user.input.asr.partial / final | 示例映射到 user.input.speech.v1 的 partial/final，迁入 user.input.speech 频道 |
| vision.pose / sound.source | 分别迁入 perception.vision.pose / perception.audio.source 频道与对应 v1 协议；保留稳定角色身份 |
| assistant.interrupt | 迁为 agent.interruption 频道上的 agent.interruption.v1；通过 sources 和 publication 绑定授权，保留目标捕获、去重与内部处理结果 |
| agent.task.request / task.request / task.input / task.cancel | 按实际语义迁入请求协议操作；不同载荷不能只重命名合并 |
| agent.task.response | 初次回复变为 Reply；后续进度/追问/终态变为任务事实 |
| runtime.message.receipt / CommunicationReceipts | 删除公开回投与 Agent 等待槽；由原调用关联回复替代，诊断内部保留 |
| action/tool 结果 inputs | 规范化为 action.result.v1，并由 signals.feedback 启用完整 handler；保留直接 Tool 的返回适配，禁止重复认知消费 |
| roundResult | 通知迁为 signals.feedback 中的 agent.round.result.v1；保留 roundFinished 与原结算屏障 |
| ActivityEvent | 保留现有可信内部绑定，不混入单次 Action 终态或整轮结算 |
| ActionCall / ToolCall 的公共调用字段 | 规范化为 action.invocation.v1 契约；入口格式、排队/直接执行和资源机制保持 |
| Writer 持久通知 | 迁移为任务状态/事件恢复证据；保留原稳定身份与未消费记录 |

示例事件协议是拟议新 schema，必须迁移所有生产者、消费者、诊断及测试；历史持久记录保留原协议版本，不把旧 payload 按新枚举强行解码。

### 6.9 Gateway 迁移文件与实施顺序

| 范围 | 计划改动 |
| --- | --- |
| Gateway/Input/SignalTransport.swift、GatewayContainer 及状态投影 | 分开事件递送与中立 Request/Reply；关联完成、超时取消、容量/回复预留、退役清理；不引入 AgentCore 依赖 |
| Agents/Support/Core/Communication：CommunicationPolicy、AgentMessaging、AgentTaskSignal、SignalObservation、DeliveryHistory | 请求/事件描述符、handler 能力目录、请求协议启用及事件配置与任务引用；移除逐对 send 权限和 topic 默认值 |
| Agents/Support/Core/Output/CommunicationAction.swift、Core/AgentInput.swift、Core/Runtime | 移除普通通信 receipt 及 InputKind；将输出等待改为关联结果；统一 ActionInvocation/ActionResult 字段、函数与输入参数快照及唯一认知消费，保留执行结果和任务隔离 |
| Agents/Support/InputGateway.swift、OutputGateway.swift、AgentGatewayAssembly/Ports、执行会话 | 注册统一端点和 handler；事件政策与订阅绑定；回复不再经过 Agent.receive inbox；执行反馈使用可信绑定 |
| Agents/Support/Communication/AgentTasks.swift、Chat/AgentCommunicationAdapter、任务协调器 | 类型化任务请求/回复、提交并观察、任务事件/游标与模型结果适配 |
| Assistant、Writer、感知角色及固定任务角色 | 按实际能力注册 handler/事件源；迁移 ASR/姿态消费者，Writer 接纳/任务恢复，保留各自业务生命周期 |
| Agents/AgentContracts.swift、Support/AgentConfigurations.swift、Core/Capability/AgentConfiguration.swift、AgentDescriptor.swift | 分离资源 schema 与运行时能力，增加 v11 signals 解码和装配校验；对 requests/feedback 做完整性与调用回报兼容校验并产生启动协议异常；从已启用 handler 投影可用协议 |
| Resources/Agents/*/Agent.json、提示词与资源验证入口 | 更新 signals 示例格式、协议及模型说明；删除旧配置和旧请求/回复/receipt 教学 |
| Actions/Support/Contracts、Gateway/Output/Dispatch/Results、Agents/Core/Output | 复用并规范化调用与终态中立契约，接入反馈协议和原结果账本；不新增 Action 消息请求或重写调度器 |
| Storage/Database/AgentMessages、WriterMessages/WriterExecutionRepository 与 SQLite 实现 | 保存可查询 Reply/状态、事件及消费游标；设计历史与未消费通知迁移，是否改表由数据设计决定 |
| App/Composition、诊断投影与 UI 诊断视图 | 注入宿主容量、绑定端口；区分 request/reply 与任务事件轨迹；UI 浅层交互不改 |
| Tests/Gateway、Agents/Core/Support/Assistant/Writer、Storage、App 及配置验证 | 替换旧夹具，覆盖配置、直接回复、任务恢复、容量、取消和代际故障 |

实施顺序：协议与持久恢复详细设计 → Gateway 中立 Request/Reply 和事件接纳回归 → 角色注册与 v11 加载校验 → Assistant–Writer 完整闭环 → 感知及其他实际路由迁移 → 删除旧路径并更新技术文档。生产切换以完整依赖闭环为单位，不能只改 JSON 后依赖运行时兜底。必要的临时兼容仅允许单向适配与单一权威状态，禁止新旧消息双发。

实施后按第 9 节同步所属技术文档。现有 Resources 文档中的历史输入/故障路由描述需随代码迁移核对，不作为恢复旧外部 Gateway 入口的依据。

### 6.10 业务兼容与恢复约束

以下记录新协议必须保留的业务行为与源码依据。通信契约以第 6.2–6.7 节为准，具体 Swift 接口和数据库迁移在实施前定稿。

| 现行业务 / 证据 | 必须保留的要点 |
| --- | --- |
| [AssistantInterrupt.swift](../../../MobileHarness/Agents/Assistant/AssistantInterrupt.swift) 与 [Assistant 打断设计](../../../MobileHarness/Agents/Assistant/README.md) | 按第 6.3 节迁移；保留 interrupted/no_target/target_expired/duplicate 内部处理证据，完成模型、Action 与播放清理后才记录 interrupted。 |
| [AssistantChatWorker.swift](../../../MobileHarness/Agents/Assistant/AssistantChatWorker.swift) | 按第 6.7 节迁移；feedback 接纳、执行事实持久化与整轮结算分别保留，删除 communicationReceipt 不得误删 roundResult。 |
| [Assistant 多源输入](../../../MobileHarness/Agents/Assistant/README.md) | 仅用户文本/ASR 在到达时满足同会话忙碌条件才进入 Decision；角色任务报告和 Action 事实不进入 Decision。保留 turn/task 关联、真实来源与输入时间线；transport kind/protocol 变化不能把运行时结果冒充用户指令。 |
| [Writer 工作流](../../../MobileHarness/Agents/Writer/README.md) | submit 仍可表达新目标、补充、回答或自然语言停止意图，Writer 保留解释职责；类型化 update/answer/cancel 只用于可信上下文已有明确语义的情况，不能强迫 Assistant 预先代替 Writer 分类。保留消息 ID、delegateID、可选 workspaceID、interactionID、事件序号和来源对话；workspace 不等于任务身份。 |
| [AgentMessageRepository](../../../MobileHarness/Storage/Database/AgentMessages/README.md) | 当前消息有接收/消费事实、不可变正文、冲突去重、领取 token、有限重试与 dead_letter。新 Reply/事件恢复不能丢失消息级拒绝、未消费终态或把接收标记当作任务完成；终态与通知的原子提交、执行权限退休与通知消费仍是独立职责。 |
| [UI 请求机制](../../../MobileHarness/UI/Shared/README.md) | 单消费者、64 个普通在途请求、独立控制槽、当前 120 秒处理期限及取消回调不是可省略的监听细节。SignalListener 适配不能把 UI 请求降为没有回复/取消的事件，也不能让页面取消只取消回执而遗留已接纳业务工作。 |
| [SpeechPerceptionMicrophone.swift](../../../MobileHarness/Agents/SpeechPerception/SpeechPerceptionMicrophone.swift)、[VisionPerception](../../../MobileHarness/Agents/VisionPerception/README.md) | PCM 只保留原生有界 FIFO，当前包处理后再取下一包；视觉保持单在途推理与 latest 候选。统一监听不得新增第二个媒体队列、逐帧 Task 或逐包模型/持久化读取。 |
| [AgentInput 元数据](../../../MobileHarness/Agents/Support/Core/AgentInput.swift)、[PoseObservation](../../../MobileHarness/Agents/Support/Communication/PoseObservation.swift) | 源/代际、因果链、时间、序号及 freshness 不因改名丢失；姿态几何、坐标系、置信度等业务 schema 完整迁移，而非只把旧载荷包进新名字。 |

#### 生命周期与恢复边界

- UI 页面取消只影响其所拥有的交互请求；普通 Scene 隐藏、角色 pause、会话 close、根 stop 必须继续区分。Writer 后台工作不能因 Assistant 对话结束或页面隐藏自动终止；根停止与明确取消仍加入实际工作。
- 生产者/消费者实例更替时撤销旧订阅 token，关闭旧实例分支并等待必要清理；新订阅不能继承旧 incarnation 的待送达事件。普通广播不自动重放，持久任务通知按稳定业务身份重新认证和恢复。
- 原请求者或执行者退出时，已有固定任务终结政策与 runtime.taskTermination 等可信清理通路必须映射。不能因为去掉旧任务消息而留下永久运行记录，也不能把所有后台任务都改成随请求者退出取消。
- Writer 向来源对话回报的归属保持；来源对话已关闭时保留待消费业务通知，由现有恢复策略决定展示，不把旧报告直接注入另一个当前对话，也不重新取得已失效的执行权限。
- 任务引用观察满载不撤销已接受的提交。保留可查询身份并显式报告观察失败；禁止调用者因观察失败自动重新提交同一副作用任务。

#### 元数据与时钟边界

不新增所有输入都必须包装的巨型信封，而是保留各信道实际需要的字段：Signal ID、稳定 source 与 incarnation、session/turn/task、root/parent、sequence 和发生/接收时间。当前最多八跳的因果保护继续保留；重投保留同一事件身份，不能每次生成新 ID 绕过去重。

区分采集/事件发生时间、Gateway 接纳时间、执行完成时间与接收时间。进程内 freshness/timeout 使用所属时钟和采集代；不得把设备 uptime 或 ContinuousClock.Instant 直接持久化后用于重启比较，也不能直接跨进程传送并比较。IPC 需另外定义时钟映射/剩余预算与重启代际，不能从 wall-clock 变化推断样本顺序。现有事件无通用默认 TTL，send 的有限等待期限不应自动变成 ASR、任务终态或所有观察的过期时间。

#### 执行反馈与参数记录的补充边界

模型工具调用、角色内部展示调用和 Writer 私有本地工具不是同一输入来源。仅经 Gateway 执行的函数适用本次 action.invocation/result 标准化；角色私有本地工具保留自身返回链。内部展示完成只回到其内部调用者，不因启用 feedback 就变成 Assistant 新输入或制造“更新 UI → 反馈 → 再更新 UI”的循环。

feedback 的参数快照不能只挂在临时 ActionResult 上：还需盘点 Assistant 对话执行证据、ModelRequestLog、历史重建和诊断投影是否保留必要输入。不能用仅 2048 字节预览的诊断记录冒充完整参数证据。旧记录缺少参数时标记 unavailable/legacy，不能重建为假定的空参数；新记录按第 6.7 节保真并执行敏感字段规则。

加入参数快照后的内存与存储预算是实施前门槛：目前结果账本限制条目数，函数参数/返回值未统一设置通用字节上限。必须盘点现有大参数（例如作品内容），明确共享快照计量、准入容量或受控存储引用方案，并完成大载荷回归；不能在 Action 已产生效果后才因保存快照超限丢结果。这里不新增未经验证的结果截断规则。

#### 最终资源与协议清单不能由示例替代

当前 Resources 除 Assistant/Writer/感知角色外，还有 Photographer、ApplicationControl、Memory 的固定任务实现和隔离诊断角色。编码前建立逐角色“原契约 → 新 handler/配置或明确保留内部绑定”的完整表，覆盖 enabled、未开放但仍被测试/内部调用的路径。示例中的空 requests 不能视为删除既有能力的批准。

资源 v11 与运行时配置 schema/严格解码器分开升级；打包 Catalog、schema 校验、角色实例注册及有效 Skill/模型工具目录同步更新。资源加载不可静默接受旧字段或把未知协议转换为空集合；持久历史采用显式旧版本解码，与启动资源严格拒绝旧版是两条不同规则。

## 7. 系统进程间信道：IPC

### 7.1 目标与接入流程

IPC 服务于 MobileHarness 自身无法完成或适合交给外部程序的任务。对方必须实现约定协议或通过明确适配支持协议；“能够打开某个 App”不构成已建立任务通信与完成回执。

```mermaid
sequenceDiagram
    participant A as MobileHarness Agent
    participant B as 本地授权与任务适配
    participant D as IPC 信道
    participant P as 支持协议的外部 Program
    A->>B: 请求外部能力与任务
    B->>D: 已授权、可编码的请求
    D->>P: 对端校验、版本与能力协商后的递送
    P-->>D: 接纳或拒绝
    D-->>B: 关联接纳证据
    B-->>A: 已接纳不等于已完成
    P-->>D: 进度、追问或终态
    D-->>B: 校验对端与任务身份
    B-->>A: 映射为本地可接纳的反馈
```

图中适配与 IPC 是逻辑职责，不表示已批准新增模块或目录。本地映射可使用 Gateway 的受控消息入口，但不能借此授予外部进程本地 Agent/runtime 身份。若未来需要传输媒体，应另行定义 IPC 媒体子协议、所有权和限额，再接到指定消费者，不能默认走普通任务消息。

### 7.2 首轮设计与实验必须回答的问题

- **平台承载**：目标 OS、进程与首个合作 App；选择公开且适用的系统接口，验证沙箱、权限、后台与唤醒约束。暂不选择 XPC、socket、URL scheme 等具体实现，也不假定任意第三方 App 可接入。
- **协议与身份**：版本/能力协商、对端身份认证、授权撤销、消息类型与编码、长度及附件限额；外部提供的 source 和 taskID 不能直接建立本地权力。
- **任务状态**：请求、接纳/拒绝、进度、追问/答复、取消、终态的状态机；定义任务与连接的独立生命周期。
- **故障与恢复**：断连、进程退出、App 挂起、超时、迟到与重复；区分递送失败、执行失败和执行结果未知。重连不能盲目重放有副作用操作。
- **可靠性**：是否持久化 outbox、回执、重试和幂等键，保留多久、谁负责清理；不得默认承诺 exactly-once。
- **数据与资源**：编码字节、附件所有权/释放、并发与队列上限、敏感内容最小披露；取消/超时不代表对端已停止，必须有确认或标为未知。

首个验证闭环至少覆盖请求、拒绝、接纳、进度、终态、取消和断连结果未知；外部能力清单与正式支持范围根据实验另行确定。

## 8. 全双工数据闭环

```mermaid
flowchart LR
    F["PlatformKit / UI"] -->|"需感知或业务处理的输入"| P["感知与意图处理"]
    F -->|"UI 交互：本地监听"| L["UI 浅层调用<br/>导航 / 缩放 / 焦点动效"]
    L -->|"本地状态与渲染"| F
    P -->|"语义消息"| G["Gateway"]
    G --> C["Cognition Agent"]
    C -->|"功能调用"| G
    G --> X["Actions"]
    X -->|"执行反馈"| G
    X -->|"改变设备或界面"| F
    C -->|"外部任务：经授权适配"| D["IPC"]
    D <--> R["外部 Program"]
    D -->|"校验后映射的结果"| G
```

传感器数据接纳、语义队列、模型生成、Action 执行与外部 Task 可以有独立进度。统一 Signal 不引入全局串行锁；每个角色按自己的状态决定排队、并行、打断或拒绝。业务影响和新观测通过因果身份关联，但不将一个回执误作另一个边界的完成证明。

## 9. 模块所有权与文档影响

本节定义三类信道的模块边界与文档归属；Gateway 具体文件迁移见第 6.9 节。

| 所有者 | 计划职责 | 实施后需同步的文档 |
| --- | --- | --- |
| PlatformKit | 硬件能力抽象、类型化传感器输入源（音视频及未来压力、温度等）、设备事实、监听资源生命周期；若选择平台 IPC，拥有相应底层机制而非 Agent 政策 | [PlatformKit](../../../MobileHarness/PlatformKit/README.md) 及 Audio/Vision/Connectivity 等实际受影响目录 |
| UI | 类型化交互源、浅层调用的本地消费与状态所有权、业务请求及回复契约 | [UI](../../../MobileHarness/UI/README.md) 及实际受影响能力目录 |
| ModelKit / Storage | 保持独立的推理/存储契约；仅在有消费需求时提供观察源 | [ModelKit](../../../MobileHarness/ModelKit/README.md)、[Storage](../../../MobileHarness/Storage/README.md)，按实际改动更新 |
| Agents | 监听消费者、语义转换、内部通信政策、任务生命周期、外部能力委派政策 | [Agents](../../../MobileHarness/Agents/README.md)、各角色及 Support/Core/Communication |
| Gateway | 内部消息递送、执行协调与反馈；独立于具体外部输入源和业务 schema | [Gateway](../../../MobileHarness/Gateway/README.md)、Input 与 Output |
| Actions | 功能执行、真实进度/结果、原生清理及失败 | [Actions](../../../MobileHarness/Actions/README.md) 与实际能力目录 |
| App | 装配三类信道所需端口、根生命周期与实现选择 | [App](../../../MobileHarness/App/README.md)、Composition 与总体设计 |
| IPC 所有权待定 | 分开定义平台承载、协议、连接/任务状态和业务适配的拥有者，再决定放置位置 | 在 docs 中完成设计后，更新最终所属模块 README |

共享 SignalListener 声明的编译归属是前置设计问题：基础模块不得依赖 AgentCore、Agents 或彼此。先审计现有中立契约目标能否合理承载，再决定公共声明或各模块自有端口的方案；不能为了统一名称偷偷新增循环依赖。新增目录或模块须按仓库规则另行解释用途、现有目录为何不足并取得批准。

总体 [Architecture](../../Architecture.md)、[Concepts](../../Concepts.md) 和 [MobileHarness 技术设计](../../../MobileHarness/README.md) 在实现后更新三类边界与跨模块流。当前阶段不把本草案写成已实现技术契约。

## 10. 实施阶段与验收

| 阶段 | 计划产出 | 完成条件 | 状态 |
| --- | --- | --- | --- |
| A：逐源盘点与接口设计 | 列出实际源接口/文件、消费者、容量、执行域、所有权；确定监听协议族、编译归属及受影响文件清单 | 覆盖音视频、UI 请求、状态/故障及压力/温度等未来载荷契约；不破坏基础模块独立性 | 已实施，工程门禁通过；专项证据见验证记录 |
| B：统一外部监听 | 先选一个已实现音视频源与一个请求源验证，并用标量传感器契约夹具验证可扩展性，再迁移其余批准范围；夹具不代表真实压力/温度硬件已接入 | 保留直接路径；取消、结束、失败、背压与请求完成回归通过；清理被替代接口 | 已实施，工程门禁通过；专项证据见验证记录 |
| C：内部通信简化 | 分离事件频道与请求协议；await send 直接回复；迁移角色配置与持久任务观察，清理旧 receipt/response 路由 | 直接回复、真实接纳与长期任务完成分离；身份/容量/取消及终态恢复不退化 | 已实施，工程门禁通过；专项证据见验证记录 |
| D：IPC 协议与试验 | 确定平台、对端、承载和协议；最小跨进程闭环与故障验证 | 真实双进程通信与断连/取消证据；清楚区分 stub 与真实外部 App | 待设计、待实施 |
| E：整体验收与文档对齐 | 多源并发及全双工回归、性能证据、当前设计与历史记录协调 | 原范围迁移/清理/必需验收完成，无旧新路径无理由并存 | 工程与文档已完成；真机多源与性能专项待执行 |

每阶段代码修改前，在本需求或关联设计中补齐具体受影响文件、接口与行为；设计改变先修订文档。迁移如需兼容期，必须说明唯一权威状态、适配方向及删除条件，不能恢复旧的原始媒体 Gateway 入口。

验证要求：

- **工程行为**：Swift 测试覆盖监听取消/join、重复消费者、慢消费、容量、代际隔离、媒体连续性、非媒体传感器的单位/时间/有效性与采样/变化交付、请求接纳与完成；内部投递覆盖来源权限、目标更替、重复/迟到与反馈关联。
- **Gateway 新通信**：验证频道/协议层级语法、主版本、显式绑定与无前缀订阅行为，以及所有注册 Agent 的统一接收入口、配置启用但缺失描述符/handler/必需操作或类型不符时启动失败及回滚、已实现未启用时不公开、空启用清单正常启动、未知协议/版本运行时快速失败、公开协议无需逐对配置且受限操作仍校验授权，以及 send 直接回复/业务拒绝、回包不依赖 inbox、deadline/取消/端点更替释放等待槽、迟到与重复回复、循环调用拒绝；Writer 提交后任务独立运行，订阅前完成、断连恢复和重启后的未消费终态可恢复；重试不重复任务。
- **Action 调用与反馈**：验证 feedback 启用与 handler/版本缺失导致启动失败、调用与结果身份及函数/参数快照贯通、配置变化不改历史输入、缺省/空值与输入/返回值区分、重投快照一致和敏感投影边界、返回值/异常/部分效果保真、非执行链伪造拒绝、结果重投去重、直接 Tool 与 Signal 不重复推进 ReAct、关闭时结果可交付或明确失败；回归原 Channel/wait、资源与真实清理语义。
- **UI 浅层调用**：验证本地导航、缩放、焦点/动效不依赖 Agent 或 Gateway 可用性；混合交互保留即时本地响应，业务查询、持久化和设备控制仍通过授权路径；本地呈现完成不冒充业务完成。
- **打断与轮次反馈**：验证多授权来源可发布、未授权来源拒绝、sources 重叠配置拒绝、发布接纳不冒充打断完成、打断目标过期/去重与控制准入；验证 agent.round.result.v1 仅在既有屏障后产生、settled 与业务成功分离、反馈失败结束等待、迟到/重复不推进新轮。
- **现行业务保留**：覆盖多源 Decision 分流、Writer 来源对话和失效 scope 恢复、UI 请求取消与控制槽、普通 Scene 隐藏与根停止差异，以及内部展示不进入模型循环。
- **全双工**：输出播放、模型工作与 Writer/外部任务活动期间仍按各源政策接纳输入；停止/打断不被普通满载队列永久阻塞。
- **性能**：同设备同配置比较当前直连基线与统一监听方案的输入延迟 p50/p95、CPU、分配、常驻/峰值内存、替换/丢帧和 PCM 溢出。不得引入额外媒体复制或无界队列；具体回归阈值先根据基线确定。
- **IPC**：真实双进程的身份、版本、容量、断连、进程退出、重连、取消确认及结果未知；平台实际允许的运行范围单独记录。
- **工程门禁**：代码变更运行 `./scripts/check.sh`；完整 Xcode 可用时运行 `./scripts/build-ios.sh`。自动测试、构建、真实模型、原生 UI、外部 App 和物理设备证据分别记录。
- **目录归属**：App/通信功能与跨模块链路验证归 Swift Tests；模型效果矩阵才归 Python experiments，不为 IPC 工程验证创建模型实验。报告归 docs/validation，原始输出按各执行入口既有约定保存。

## 11. 实施前待决策项与范围

以下事项须在对应阶段编码前定稿；配置示例不能替代完整的角色清单或接口设计。

| 范围 | 待确定内容 |
| --- | --- |
| SignalListener | 精确接口、请求/回复扩展的组织方式、共享声明编译归属、首批迁移源与各源容量；请求完成和取消语义必须保留 |
| send 与任务观察 | Swift 签名、错误类型、agent.task.v1 必需操作集、固定任务与 Writer 消息式接纳映射、任务引用/游标及消费事务、历史通知迁移 |
| 角色配置 | 逐角色完整 requests/feedback 清单、打断授权发布者与订阅 sources、受限操作的访问上下文 |
| 容量与执行证据 | 大参数/返回值快照与持久化预算、取消控制在全局槽/字节满载时的预留、回复预留算法、诊断字段最小集合 |
| pub/sub | 源内顺序、分支独立容量与控制准入的具体实现；目标顺序契约不能当作当前已有的全局 FIFO 保证 |
| IPC | 首个目标平台/合作程序、承载技术、身份与时钟、断连恢复及职责归属，见第 7 节 |

原文档阶段的待决策清单保留为需求背景；非 IPC 的接口、逐角色清单、容量与存储选择已在第 13 节定稿并实施。未新增目录或依赖。IPC 仍待设计；真机性能、真实模型与跨进程验收不由工程检查替代。

## 12. 实现审计与首批修改（2026-11-19）

开发分支：`feat/signal-redesign`。用户已授权依据本需求开展修改。以下为分阶段实施清单，不代表整份需求已经完成。

| 优先级 | 当前证据及差距 | 修改归属与接口影响 |
| --- | --- | --- |
| P0 | Gateway/Input/SignalTransport.swift 的普通与 cleanup 递送共用全部 256 槽 / 8 MiB；普通负载可使停止清理拒绝 | 首批保留 16 槽 / 256 KiB 给现有可信 cleanup；普通准入限制为 240 槽 / 7936 KiB，总上限不变。不是未来 agent.interruption 的授权控制端口 |
| P0 | register 更换 incarnation 只换 token；已进入 receiver 的旧代工作未取消，返回也未校验 | 首批取消涉及旧 token 的在途工作，接收返回后检查取消与端点身份；保留 receiver 原始异常，不将失败改成取消。同步注册不等待旧业务退出，transport 仍持有任务直到 join；不可撤销副作用仍由业务所有者负责 |
| P1 | PCM 已有单消费者、64 包 FIFO 与溢出失败；CameraFrame 为 latest；各源生命周期接口仍不同 | PlatformKit Audio/Vision、Agents 感知、UI 请求逐源设计 listen/cancel/join；保留原生缓冲，不让基础模块依赖 AgentCore。具体共享编译归属尚需确定 |
| P1 | AgentContracts、CommunicationPolicy、Resources/Agents 仍用 v10 inputs/sends/topic | 先确定类型化描述符与逐角色能力矩阵，再同时迁移加载器、资源、装配与所有消费者到 v11；不能只替换 JSON 名称 |
| P1 | 当前 send 返回投递接纳，Writer 后续以 agent.task.response 反馈 | Gateway 中立 Request/Reply + Agents 语义授权，取消/deadline/循环调用释放等待容量；Writer/Storage 任务状态与游标事务迁移后删除旧回执路径 |
| P1 | ActionResultLedger 与轮次屏障已有独立执行语义 | Agents 输出适配器与执行快照迁移到 feedback；保留函数参数快照、重投去重及屏障后结算，不再次执行业务 |
| P2 | pub/sub 仍按旧 contract/source/topic 精确匹配 | 显式 EventChannel/Protocol 绑定、sources、事件变体策略、启动全量校验与回滚；打断需要独立授权和准入，不能借 cleanup 标记开放权限 |
| 待决策 | IPC 无首个合作程序、承载或对端身份方案 | 在真实平台与对端明确后设计，当前不添加空壳 IPC 或虚构验收 |

首批受影响文件：`MobileHarness/Gateway/Input/SignalTransport.swift`、同目录 README、Gateway README、`Tests/Gateway/Output/GatewayContainerTests.swift`。模块依赖与跨模块接口保持不变，不新增目录。后续范围在编码前补充逐源接口设计和逐角色迁移清单。

首批验证：Swift 工程测试覆盖普通字节容量耗尽后清理仍可进入、总预算拒绝、源/目标更替取消及错误保真；运行 check.sh 和 build-ios.sh，证据记录于 docs/validation/Signal-Redesign-Validation.md。此批不声称统一监听、v11、任务游标、控制广播或 IPC 已完成。

### 12.1 已核对的外部源基线

| 源及当前接口 | 消费者/执行域 | 容量、生命周期与迁移约束 |
| --- | --- | --- |
| PlatformKit/Audio/MicrophoneFrame.swift：AudioCaptureObserving.subscribeCapture | SpeechPerception；原生采集回调生产，角色任务消费 | 每代单消费者、64 包 ordered；overflow 终止并抛错；保留 generation、PCM 连续性与原生缓冲，不增加转发 Task |
| PlatformKit/Vision/CameraFrame.swift：CameraFrameReceiver.subscribe | VisionPerception / 获准媒体消费者；原生回调生产 | NativeInputBroadcast.latest、每订阅 1 帧；保留 sequence/capturedAt，重新 begin 关闭旧观察；订阅不激活设备 |
| PlatformKit/Core/NativeInputBroadcast.swift：subscribe | 平台事实消费者；Mutex 管理注册 | 最多 16 订阅，latest=1 / ordered=64；ordered overflow 结束该分支并报告，latest 计替换；目前没有显式订阅句柄及 join |
| UI/Shared/UIRequests.swift：listen / listenControls / submit | Agents/Support/AgentUIRequests.swift 接到负责角色；MainActor | 单消费者，普通 64 + 控制 1；独立 generation、request ID、accept/complete、取消回调；迁移不能将 accept 当作 Reply 或取消完成 |
| UI/Camera/UICameraContainer.swift：CameraFactsObserving.observeFacts | Photographer；MainActor | 状态事实接口须单独核对初始快照、合并与关闭语义，不能从媒体队列策略推导 |
| UI/Root/NavigationState.swift 与组件原生交互 | UI 自有状态；MainActor | 本地浅层交互保留原生同步路径；业务查询与设备操作继续请求负责角色 |

后续精确接口设计应先覆盖订阅句柄取消/加入与请求完成，再迁移调用方；不能仅以重命名 subscribe 为 listen 宣称满足 SignalListener。压力/温度只纳入未来类型化测量夹具，不声称当前存在设备接入。

首批实施结果：上述两项 Gateway P0 修正和 Swift 回归已实现，check.sh 通过；Simulator 编译通过但最终资源校验失败，详见 [验证记录](../../validation/Signal-Redesign-Validation.md)。A–E 阶段整体仍未完成，后续清单保持有效。

## 13. 非 IPC 完整迁移实施契约

用户确认范围：实施外部 SignalListener 及其分类、全部实际生产消费接线、Agent–Agent 与 Agent–Action 的新内部协议；IPC 不实施。第 12 节首批修正不是本轮交付终点。

### 13.1 外部监听分类与所有权

SignalListener 作为类型化监听契约，按交付语义细分 MediaSignalListener（PCM/帧）、StateSignalListener（快照、环境及故障事实）、RequestSignalListener（UI 业务请求及 Reply）。传感器标量/向量使用 SensorSignalListener，声明单位/时间/有效性，不假设等同媒体。UI 本地手势仍原生处理。请求接纳与完成分离，控制请求独立容量；监听本身不启动硬件。消费者持有唯一消费任务，取消先阻止接纳再加入任务及源解除订阅，不增加转发队列。

用户已决定保留现有目录、采用模块自有监听契约，详见第 13.4 节。不创建 SignalKit。UI、PlatformKit、ModelKit 仅使用系统库实现自身协议族，App/Agents 通过公开端口装配生产者与消费者。

### 13.2 中立 Request/Reply

Gateway 拥有 `SignalRequestProtocol<Request, Reply>` 类型化描述符及端点注册 handler。描述符保存显式 protocol ID、Request/Reply 类型、请求字节计算、最大回复预算和默认 deadline。`request(source:target:using:request:) async throws -> Reply` 沿原调用返回，不进入源 inbox，不产生 response topic。完整启用检查属于 Agents 静态能力装配；Gateway 仅检查中立描述符与活跃身份。

同一端点注册统一身份，事件接收与协议 handler 分开绑定；未知/未启用、类型不符、过期和循环调用显式拒绝。普通请求预留请求与最大回复的合计预算，控制请求不能由载荷自由声明身份。当前 task-local 调用链最多八跳并拒绝递归目标。端点更替取消旧 handler 工作，取消/deadline 后加入清理再释放所有权；无法合作停止的业务不能假装清理已完成。新文件放 Gateway/Input/ 现有目录，更新所属 README、Gateway 模块 README 与工程测试。

### 13.3 执行与资源配置

保持 Gateway 执行设施及 Channel/wait/资源许可，仅统一可信调用/结果协议和不可变输入快照。ActionResult 携带函数与参数，直接 Tool 保留唯一返回消费者；feedback 只允许可信 owner/context 进入。v11 资源与运行时编译配置联动迁移，静态能力目录与启用集合严格区分；固定任务角色的现有能力保留并逐操作建 handler。Writer 状态、终态 outbox 与消费游标在既有存储目录迁移，历史数据显式按旧版本读取，不重新解释或重放动作。

### 13.4 已确定的模块自有监听接口

用户选择保留目录，各模块自有契约，不新增 SignalKit。PlatformKit/Core 在 NativeInputBroadcast.swift 同目录实现 SignalListener 协议及 MediaSignalListener、StateSignalListener、SensorSignalListener；UI/Shared 在 UIRequests.swift 同目录实现 UI 自有 SignalListener/RequestSignalListener。两边均不导入对方或 Gateway。契约按语义一致，不以共享 Swift 继承树制造基础模块依赖。

监听句柄为 AsyncSequence，保留唯一原生流；cancel 关闭源接纳，join 等待解除注册。消费者正在执行的工作仍由其所属 Agent 的消费任务加入，源 join 不冒充业务工作完成。普通源不新增缓存；PCM 64 包 ordered，图像 1 帧 latest，状态按原生 source 原有有界策略。Source 描述包含稳定生产者和交付政策；消费者为注册句柄的持有者，不在硬件 SDK 中硬编码业务角色。

改动 MicrophoneCaptureInput.frames 为 MediaSignalListener，AudioCaptureObserving.listenCapture 取得带代际的句柄；CameraFrameObserving.listenFrames 返回 MediaSignalListener。Speech/VisionPerception 持有消费任务并在退出时 cancel/join 对应监听句柄。UIRequests.listen/listenControls 返回 RequestSignalListener，取消绑定 listening token；AgentUIInputs 在加入旧消费任务前关闭句柄。测试替身同步返回新契约，不保留旧 subscribe 接口。

外部事实接线同时覆盖：UI CameraFacts → Photographer，以及 Actions NexArmControlService.connectionFacts → ApplicationControl（经 ActionsBusinessBindings、AgentHostBindings、App 注入）。两者迁为 StateSignalListener，保留初始快照、latest 和 16 订阅上限；消费任务退出 cancel/join。设备事实机制复用 PlatformKit 已有 NativeInputBroadcast 的公开句柄，不使 Actions 进入 PlatformKit 或 UI。改动所属根契约/组合文件、NexArm 根 README、ApplicationControl README 和 Camera/UI Shared README；编译依赖不变。

### 13.5 内部配置与协议迁移细化

新配置仍由 Core 的 CommunicationDeclaration 值拥有，字段整体替换为 requests/feedback/publications/subscriptions；不保留 inputs/sends/topic 的资源解码兼容。资源 v11、编译配置 v9 分别严格解码。CommunicationContract 显式区分请求协议和事件 channel，事件变体位于 AgentMessage.event；ASR 的 partial/final 共用 user.input.speech.v1，不能通过同名前缀匹配。

角色 requests：Writer、Memory、Photographer、ApplicationControl 启用 agent.task.v1；Assistant、SpeechPerception、VisionPerception 为空。固定任务角色现有任务准入保留，不因示例空数组删除。feedback：所有经 Gateway 调用的角色启用 action.result.v1；Assistant 另启用 agent.round.result.v1。Tool 和 scheduled Action 在同一个 action.result.v1 下保持各自唯一接纳入口，Activity 保持可信内部绑定。

静态 publications/subscriptions 按第 6.4 节；任务 events 由已接纳参与者的运行时作用域动态路由，不要求静态角色对权限；普通定向请求仅按目标的已启用协议和操作权限准入，不再检查发送方逐对 sends。生产切换同步更新 AgentContracts、AgentConfiguration/AgentConfigurations、CommunicationPolicy、OutputGateway/InputGateway、AgentCommunicationAdapter 与各角色资源；测试夹具同步迁移。

普通通信调用直接使用已绑定身份的 AgentMessaging 异步返回链。OutputGateway.consumer 在绑定输出端点时给角色注入该端口，Assistant worker 和固定任务协调器直接等待返回，不再通过输出 mailbox + runtime.message.receipt 往返。Writer 的初次 Reply 表示持久消息接纳，后续 started/进度/终态仍为可恢复业务事实，不能把模型处理完成放在通信等待槽中。

类型化任务请求使用 AgentProtocolRequest（可信 input + submit/update/answer/status/cancel）及 AgentRequestReply（requestID/reference/可选 state）。AgentMessage.operation 表明请求操作，不使用 topic 区分操作；AgentTaskQuery 保存已有 scope 的 status/cancel。固定任务查询核对 context task registry 的完整 scope；Writer 查询/取消核对原持久消息的 sender/receiver/session，取消加入真实清理。自然语言 submit 不预先强制分类，可信 update/answer 可显式表达意图。

启动能力目录在 AgentContracts 中以代码注册角色实际 receiveRequest 方法和完整操作集；资源启用集合逐项校验 unknownProtocol、missingHandler、missingRequiredOperation、schemaMismatch 等，空 requests 合法。feedback 实现包含直接 Tool 的返回适配，不要求把返回值再投进 inbox；executeDirect 选择唯一直接接收链；executeReturning 为 UI 固定多步流程保留唯一配对 ToolResult 认知入口，直接值仅用于 UI 响应。

相机执行入口 start/switchCamera 返回的预览流也统一为 MediaSignalListener；Actions/Camera 的 CameraRuntimePorts/CameraCoordinator、App/Composition/AgentResourceBindings 与测试替身同步改类型。receiver.begin 保留同一个原生 latest 缓冲，句柄取消只解除该代预览输出，不隐式停止硬件或关闭其他获准观察者；设备停止仍由 CameraCapturing.stopAndWait 完成。

持久恢复沿现有 AgentMessageRepository 增加 taskEvents/consumeTaskEvents：基于不可变消息的 SQLite rowid 提供每个 taskRef + receiver 的有界页面和持久消费游标，提交游标与 consumed_at 在单一事务更新。新增表放既有 AgentMessages schema 文件，不新增目录。新 schema 版本在现有数据库上非破坏性加表；历史协议名和 payload 不重写。Writer 的终态/拒绝 outbox 改为写 agent.task.events.v1，查询明确读取新旧版本并在 Agent 解码边界识别历史版本。sourceSession 以新消息的显式持久字段保存，未知历史字段保留为空，不用当前会话补造旧身份。

ModelKit 资源 revision 是既有外部状态源，也迁为该模块自有 StateSignalListener：Support/Core 放纯生命周期契约，Management 的 ArtifactChanges 仍持有唯一 latest(1) / 16 订阅注册。ModelManager/ModelArtifactsManaging、AgentRuntime 与 ApplicationControl 的 ResourceObservationSession 同步改类型并加入取消解除注册。不改变推理接口、不增加轮询，不让 ModelKit 依赖 UI、PlatformKit 或 Agents。

持久迁移精确文件：Storage/Database/AgentMessages 的 Record/Row/Repository 增加 sourceSessionID 与任务事件页面、消费游标；SQLiteSchema 从 20261113 非破坏性迁至 20261119（加可空来源会话列与 task_observation_cursors 表）。原支持的 20261110–12 先完成既有迁移，再加 Signal 表/列。游标按 taskRef + receiver 唯一，单 receiver 最多 256 个，不回退；确认和对应事件 consumed_at 同事务提交。历史 sourceSessionID 为空保持未知，不能拿当前会话覆盖。WriterMessages SQL 新写 v1 事件，恢复读取显式包含历史 agent.task.response/writer.completion。

Action 输入快照在 FunctionContracts/FunctionRequest.swift 定义 ActionInvocationSnapshot（action.invocation.v1、完整函数地址、原始参数字典），不包含附件/服务/凭据对象。字段沿原调用复用不可变 Swift 字典；原生凭据仍由现有受控引用接口提供，不展开。新 ActionResult/ToolResult 的 invocation 为可选，仅旧记录或尚未成功解析函数地址时为空；空参数字典与缺失快照区分。scheduled ledger 从实际 ScheduledAction 捕获；直接 Tool 从同一 FunctionInvocation 捕获；执行前拒绝也保留已解析的输入。结果重投复用原快照。单次输入快照最大 4 MiB，ledger 活跃输入合计 32 MiB、历史输入合计 32 MiB，准入前拒绝超限；历史按原有最旧淘汰策略并增加字节淘汰约束。现有返回值与 ActionReport 的业务限制继续由所属函数拥有，不新增执行后截断或丢弃结果规则。

打断控制准入采用可信适配器设置的中立 control lane，与 cleanup 区分：control 仍受根可用性检查，cleanup 可在排空期进入。普通发布/分支/transport 不能占用预留的 16 槽和 256 KiB；获授权 agent.interruption.v1 发布才由 Agents 设置 control 标记，接收端继续验证 sources 与会话目标。全局发布预算拒绝必须抛错，不再仅记录 dropped 后伪装发布成功；不可丢弃 final/控制分支拒绝必须通知负责者。

agent.task.v1 的 Request 是明确的联合载荷：自然语言 AgentTaskRequest、既有固定任务 AgentTaskSignal、已有引用的 AgentTaskQuery；AgentProtocolRequest 保存这个类型化 body、操作和可信上下文。自然语言请求值移入现有 AgentCore/Communication，避免 Gateway 以任意 AgentInput 类型冒充协议 schema。描述符注册的 Request/Reply 泛型为 AgentProtocolRequest/AgentRequestReply；各角色按自身业务接纳或明确拒绝载荷变体，保持原固定任务与 Writer 的解释职责。

大参数采用执行前归档：大于 128 KiB 的 ActionInvocationSnapshot 由 OutputGateway 经现有 AgentMessageRepository 的中立 Data 接口写入 invocation_evidence；单条原始编码上限 4 MiB（JSON 实际字节计量）。归档失败或未注入持久端口时在执行前拒绝。内存中保留原参数，持久反馈仅编码 function/reference/原始字节计量，不把大字典复制进 512 KiB Context.Record；读取归档可恢复完整参数。小快照完整内联。Storage 不理解函数参数，只校验 ID、字节预算和不可变冲突。新表与任务游标同属 20261119 非破坏性迁移，sourceSession/历史记录保持上述规则。

任务事件复用内部订阅分支而不是开放为普通 send 请求。任务运行时在提交接纳后建立 reference/source/observer/session 的动态观察（最多 256），并可依据已认证的持久请求恢复。普通 publish 只等待分支准入；持久 outbox 使用任务运行时私有的消费确认屏障，以实际 handler 接纳更新投递事实，不能把发布接纳当作通知已消费。两者共用同一任务观察表和递送设施，不双发。普通 AgentMessaging.send 在进入 Gateway 前要求请求 operation，事件不得先产生效果再因缺少 Reply 报错。

事件分支采用源 incarnation + channel + consumer 的独立有序链，每分支最多 16 个在途/待递送事件，满载仅拒绝该分支；不同消费者互不等待。总分支预算仍有界，跨源不承诺总序。直接请求保持并发，不进入事件有序链。媒体 latest 及姿态发布替换继续由既有原生/角色源拥有，本次不凭配置制造隐藏丢弃策略。额外展示观察者最多 8 个活跃回调，满载独立报告拒绝，不能耗尽所有事件槽；回调错误必须由负责者收到，不再静默吞掉。

Gateway 内部事件设施进一步收敛：新增现有 Input/ 目录下的 SignalEvents.swift，由 SignalTransport 唯一持有 SignalEventTransport；中立 EventChannel、类型化 EventProtocol、绑定生产者端口及静态/动态订阅归 Gateway。Agents InputGateway 保留语义授权、活跃角色绑定、任务参与者认证和诊断投影，删除其重复的 publication Task/队列/字节预算。事件顺序、独立分支容量、观察者上限、取消/端点退役/根停止加入均由 Gateway 设施拥有；Root 向隔离 scope 传递同一份中立容量配置。静态订阅绑定可在来源暂未活跃时存在；不启动来源。动态任务订阅通过 scope 独立字段匹配，不写入 JSON。普通 publish 返回中立接纳引用；只有任务持久投递与测试屏障会等待实际分支处理。

监听句柄本身也执行单消费者限制：同一个句柄及其值拷贝只能建立一个迭代器，第二个迭代器显式抛出 duplicateConsumer，不能让两个消费者分走同一 FIFO。多个订阅仍由生产者的独立注册提供。State/UI/ModelKit 消费循环同步接纳显式迭代失败；join 终结并等待源解除注册，业务处理任务仍由消费者所有者加入。SensorMeasurement 声明可选量程、采样频率和校准身份，valid 不接受缺失值，unavailable 不伪造零值。

Signal 的稳定身份同步贯通：AgentMessage 可携带生产者已分配的 id；新 AgentTaskSignal 在构造时保存 id（request 固定为 scope.id），Writer 事件使用业务 eventID，重投不重新生成 ID。旧持久 Signal 缺少该字段时保持 nil，Writer 历史事件通过已验证的原业务 eventID 恢复递送身份；不改写原 payload。Writer 终态重投的 parent/root 固定为原消息/任务引用，不再每次生成随机因果根。

端点替换同时关闭旧代际的事件生产／订阅绑定并加入其事件分支；端点注册在清理期间可挂起，返回前再次核对新 token。任务消费确认在 Storage 事务内推进连续已消费事件的游标，不越过前面的未消费事件。公开文本委派目录由真实代码适配能力与已启用协议生成，不硬编码发送者/目标配对。

构建验证同时核对 Agents 的资源边界：Package.swift 显式排除 Resources/Models，避免 Xcode 为 Agents 自动编译不属于该 target 的原生模型。模型仍由 ModelKit 的声明与资源装配路径拥有；本次不移动或删除模型源资产。

启动校验还将静态订阅与角色代码的事件处理能力匹配（频道、协议、可消费变体），发布声明与实际生产能力匹配，反馈与角色处理能力匹配。只在 JSON 中添加订阅或发布不能产生处理器；实例绑定复用同一代码注册。

原生 Bluetooth 状态同样迁移：NexArmBluetoothLink.listenUpdates 返回 PlatformKit.StateSignalListener，原生 driver 直接写 NativeInputBroadcast，不经过中转 Task。Actions 的运行所有者先注册监听再读取已有 reflectedState 缓存；无缓存保持未知，不调用会懒建驱动的 status()；暂停/恢复重新注册独立代际，退出关闭并加入监听。各测试替身实现同一端口。

返回路径明确分开：既有 UI 固定多步工作流使用 executeReturning，其唯一认知消费仍为配对 ToolResult，直接返回仅用于 UI 响应/失败投影；Writer 等直接消费原生结果的流程使用 executeDirect，禁止再回投 inbox。executeInternal 仅用于已声明内部呈现。三者不共用一个模糊的“returning”开关。

Writer 的任务入口与存储所有权校验使用认证 requester 和原始记录的 sender，不保留 Assistant→Writer 的隐式配对限制；进度、拒绝与持久终态按原 requester 返回。补充/取消必须与原任务同一发送者且同一 session，不能让放开协议访问变成跨任务修改权限。

动态任务观察不依赖静态 subscriptions 是否为空：每个角色保留统一 observation 接收入口，真正的接纳仍受入站协议、静态订阅或经过授权的任务绑定限制。纯请求调用方也能接收可信终止事实；不能通过清空静态列表移除这个运行时入口。

### 13.9 实施结果与验收边界

非 IPC 源码及资源迁移已完成，保留模块自有监听契约，无新增目录/模块/第三方依赖。完整 check.sh 与五个 iOS Simulator scheme 通过，最后的原生缓存读取调整经独立 NexArm/Bluetooth 回归通过。生产者/消费者、容量、取消加入、直接 Reply、任务观察与历史快照的当前契约已同步到所属 README。详细计数、失败修复记录和日志见 [Signal 验证记录](../../validation/Signal-Redesign-Validation.md)。

本需求仍保留真实设备多源全双工与同设备性能基线的专项验收；本次工程替身与构建不替代这些证据。IPC 按用户指定不实施，原范围在第 7 节继续保留，不把尚无真实双进程证据的设计归档为完成。

## 14. 消费者拥有订阅，生产者独立发布

用户复核要求替换第 13 节的自动观察方案：发布方不知道订阅者，不检查其 ready 或接收能力，发布不能创建、恢复或取消任何消费者订阅。Writer 无需 JSON publication 或初始化注册；任务事件描述符提供代码拥有的按需发布能力。静态 publication 继续用于常驻语义源，所有 publication 都只等待 Gateway 接纳。

Agents/Support/InputGateway 删除 TaskObservation 表、observeTask/forgetTaskObservation 和 dynamicTask 分支；OutputGateway 删除 Reply/上报触发的订阅、终态自动退订及发布路径的接收者初始化/状态查询，也不为发布诊断预先扫描静态订阅名单；被动诊断只从 broker 已结算分支生成最多 16 个目标证据。共享层仅提供通用频道、协议、来源、scope、session 过滤及显式句柄；入站 Agent 事件由中立频道契约和 broker 已绑定分支准入，不保留任务协议专用的隐式观察通行分支。宿主 runtime 直接控制反馈仍由认证 ExecutionOwner 通道准入，与 Agent 发布订阅分离；保留停止时可信终止事实的交付。事件受众表示任务隐私所有权，不表示订阅者身份或状态；Gateway 只执行中立过滤。订阅者实例认证与历史事件 session 过滤分别校验，允许当前消费者恢复自己的旧任务。

AssistantChatWorker 在发送请求之前自行订阅，按生产者、任务引用和 session 匹配，持有最多 256 个句柄。补充/取消复用原订阅，发送失败回收新句柄，终态成功应用并确认后退订，停止时取消并加入。恢复从自身持久请求重建订阅；兼容 AgentTaskRequest 的已支持历史协议名，未知旧 session 不伪造。订阅建立与停止通过所有者代际围栏隔离；最后订阅退出后若新订阅在旧 worker 收尾期间进入，收尾重新检查并启动唯一 worker。发送前取消同样释放新句柄。单个有所有者的补读 worker 每次每任务读取最多 32 条，失败保留有界诊断并重试，消费方自己应用、去重及确认游标，不能要求 Writer 因拒收重发。

WriterNotifications 只根据本地 publication 准入推进 outbox，拒收、未监听、消费者暂停都不影响生产者。移除消费确认型发布 API；Gateway wait/flush 仅供测试和框架诊断。取消自身订阅时保留当前消费回调的完成确认，关闭后续分支。

Storage schema 递增为逻辑修订号 20261120：published_at 独立记录源端发布接纳；received_at/consumed_at/任务游标独立记录消费。20261119 非破坏增加 published_at 并回填旧事件的实际已递送证据；更早受支持版本串行迁移。消费者确认不改变任务事件的发布 outbox 状态。WriterDelegationNotification 的 published 字段替换 delivered，retired 仍独立表示执行权限清理。

受影响代码为 Core/Communication 通用契约、InputGateway/OutputGateway 中立适配、AgentContracts 生产契约、AssistantChatWorker 消费所有权、Writer 与固定任务发布、Gateway/Input/SignalEvents 泛型过滤和取消、Storage 的恢复查询及发布标记。同步更新总体设计与各目录 README、验证记录；不新增目录或依赖。回归覆盖无订阅发布、暂停/取消、任务/session 隔离、消费回调退订、无人监听期间的持久终态恢复及 schema 非破坏迁移。

## 15. 实时 Pub/Sub 与 Assistant 常驻 Writer 订阅

按用户最新确认：Pub/Sub 是相互独立的尽力实时事件，无订阅、迟订阅、分支溢出或消费拒绝均不向发布方提供接收确认，不要求源端因消费失败重发。publish 的成功仅表示本地准入；指定目标的 send 返回直接 Reply，失败/超时/取消显式传播。既有持久任务结果和消费方业务对账独立于 broker，不把其恢复称为 Signal 重放或可靠 Pub/Sub。

Assistant 的 Agent.json 从启动装配开始静态订阅 agent.task / agent.task.events.v1，来源 writer；AgentContracts 注册对应真实处理器。Writer 保持 publications/subscriptions 为空，代码按需 pub。CommunicationPolicy 不再要求订阅源在当前配置集出现或声明 publication；只校验订阅自身的协议、频道、来源格式与容量，生产者自己的发布权限仍独立校验。

AssistantChatWorker 将任务观察集合重命名为任务跟踪集合（最多 256 项），任务开始前登记生产者/任务 ID/session，不为 Writer 创建 per-task broker 句柄；任务结束/失败只移除跟踪，不关闭常驻频道。其他角色的既有动态订阅仍由发起角色持有。按本角色声明判断静态覆盖，避免 Writer 特判进入 Support。无匹配跟踪或 session 的静态事件忽略，不能污染当前任务；格式、来源和不可变事实仍验证。已有单 worker 的任务结果对账保留，与订阅生命周期分离。公开状态使用 trackedTasks，不能把业务任务计数命名为订阅数。

修改文件：Assistant/Agent.json、AgentContracts.swift、Core/Communication/CommunicationPolicy.swift、AssistantChatWorker.swift、AssistantContainer.swift；更新任务/通信/配置回归。同步总体流程、Agents/Assistant、Agents/Support/Core/Communication、Resources/Agents、Gateway/Input 的 README 及当前概念/架构说明。回归验证启动无任务即有 Writer 订阅、任务前后数量不变、多任务/session 隔离、停止/重建端点清理、发布前无消费者及迟订阅不补发、send 的真实 Reply/错误边界。无新目录或依赖。

常驻订阅在没有执行过任何任务时也必须随 Agent 停止而清理。OutputGateway.consumer 装配消费者端点时即安装既有通用生命周期观察器，不再等首次执行才安装；角色停止/实例替换关闭旧端点及其订阅。该机制不包含 Writer/Assistant 分支，也不由 publication 触发。

频道级静态监听省略 scope 时匹配该频道所有事件 scope；显式 scope 仍做精确过滤。Gateway/Input/SignalEvents 将空 scope 明确定义为通配，并拒绝同一端点、来源交集且 scope/session 交叠的重复绑定，防止常驻监听和任务监听造成双重交付。Gateway 工程回归覆盖多个 scope 的常驻交付及交叠拒绝。

Writer 的工程请求方夹具也采用相同所有权：装配时显式绑定 Assistant 静态消费端点，WriterTestRequester 只保存有界任务/session 跟踪及独立持久结果对账，不再为每个委托创建动态订阅。对应修改位于 Tests/Agents/Writer/WriterAgentTests.swift 和 WriterCommunicationFixture.swift，不修改实验运行器。

## 16. Publication 声明与静态配对校验

按用户进一步确认，保留 publications 作为每个 Agent 的实际生产协议声明，并恢复启动时 pub/sub 双方配对校验。本节替代第 14/15 节关于 Writer 无 publication 声明、允许订阅源缺失配置的决定；运行时发布仍不感知消费者存在、ready 或接收结果，静态校验不探测在线实例。

Writer、Memory、Photographer、ApplicationControl 及拥有固定任务报告代码的 Assistant 声明 agent.task / agent.task.events.v1；保留语音、姿态、中断的原有发布声明。AgentContracts 的生产实现目录验证这些声明与真实代码能力一致，消费声明验证实际 handler/variants。CommunicationPolicy 校验每个静态订阅源存在配置并声明匹配频道/协议；允许声明的 publication 没有任何订阅，来源不必启动或在线。配置自身的版本、频道、协议、来源及容量校验保留。

移除 onDemandPublication 的隐式授权绕过，实际 publish 要求本角色声明的 publication；通用端点绑定按声明注册源，不创建或启动消费者。Assistant 的 Writer 频道仍为启动起常驻订阅，业务任务跟踪与频道生命周期继续分离。无接收确认或 broker 补发，send 仍等待指定目标的 Reply。

受影响文件为四个生产者 Agent.json、AgentContracts.swift、CommunicationPolicy.swift、InputGateway/OutputGateway、配置/通信/任务工程夹具；同步 owning README、总体设计、当前术语和验证记录。回归覆盖缺失发布声明/缺失来源配置/频道协议不符/伪造代码能力时启动拒绝，合法声明但无消费者时成功发布、订阅源未运行时独立建立常驻监听，以及任务期间订阅数保持不变。无新目录、模块或依赖。

## 17. Action feedback 重投上限

复核结论：Action 结果必须被接纳或明确终结（功能已产生副作用，整轮结算依赖结果），但重投只应用于接收端暂时拥塞，不应无限进行。第 6.7 节的“只重投不可变结果、不重新执行功能”保持不变。

变更：ActionResultLedger 为每条已完成结果记录完成时间，重投总时长上限默认 60 秒（ChannelScheduler 可注入，用于测试）。超限后该记录以 `expired` 终结，保留结果与入参快照作为诊断证据，计入 `expiredResults`；`finishRoundDelivery` 将 `expired` 与 `closed` 同样视为结果未送达，抛出 resultDeliveryFailed，整轮结算为失败，不能报告 settled。作用域关闭、停机仍按 `closed` 处理。`accepted` 仍只表示接收端准入，不表示业务已处理。

受影响文件：ActionResultLedger.swift、ChannelScheduler.swift（第 19 节后位于 Actions/Support/Shell）、对应 README、Tests/Actions/Execution/ActionLifecycleTests.swift。无新目录、模块或依赖；60 秒是待验证的设计值，不是性能结论。

## 18. 消息传递的命名与分类标注

决定：不为统一术语重命名目录或类型，现有名称按职责保留（Gateway/Input 为 Agent–Agent 传输，Gateway/Output 为 Agent–Action 执行调度）。`InternalAction`、`InternalTool` 指不经注册、由角色直接发起的展示调用（灵动岛、字幕、错误 Toast），与 Signal 分类无关，不改名。

变更：在消息传递相关的类型定义处用一行注释标明所属类别。外部 Signal：各模块自有 SignalListener。内部 Signal：Gateway 的 SignalTransport / SignalEnvelope / SignalRequestProtocol / SignalEventTransport、Agents 的 AgentMessaging / InputGateway / OutputGateway，以及 Agent–Action 的 ExecutionEnvelope / ScheduledAction / ExecutionResult。Gateway README 同步写明该分类。仅改注释与文档，无行为、接口、目录或依赖变化。

## 19. Gateway 回归 Signal 通信，执行 Shell 归 ActionsContainer

目标：Gateway 只拥有内部 Signal 的端点身份、准入、路由与有界递送，统一承载四类内部 Signal——Agent→Agent 请求（send）、Agent↔Agent 事件（pub/sub）、Agent→Action 调用 Signal、Action→Agent 反馈 Signal。Agent 产生的 function token（XML 调用、Tool 调用、角色内部 Action）继续经 Gateway 送达 Action，Agents 不直接依赖 Actions。Channel 排序与并行/串行算法、Tool 直接调用、资源锁与交接、执行账本、结果重投由 ActionsContainer 拥有，因其离资源与真实执行更近。

边界与接口：
- FunctionContracts（中立）接收原属 Gateway/Output 的契约：ExecutionEnvelope、ScheduledAction、ExecutionSchedulingDirective、ExecutionResult、ActionSchedulingError，并新增 `ActionExecutionEngine` 协议，描述调用、调度指令、结束/取消、直接调用、资源租约、整轮结果送达与 Signal 绑定。Gateway 与 Agents 只依赖该协议，Actions 不 import Gateway。
- Actions 新增 `ActionExecutionCoordinator`（实现该协议，持有 ChannelScheduler、DirectExecutionDispatcher、ResourceCoordinator、ActionResultLedger、ActionExecutionLedger 与自有准入），由 ActionsContainer 在业务配置时构造；引擎直接使用容器自身的 prepare/execute，不再经 App 注入 `ActionsExecutionPort`。资源定义、停止回调与 NexArm、Camera 的资源访问在 Actions 内部绑定，App 的 CameraResourceBinding 与 Agents 的 bindResources 删除。
- Gateway：`GatewayConfiguration` 改为携带引擎与反馈出口；`GatewayExecution` 在 Gateway 准入通过后转发到引擎；绑定时把 `signals.validateExecution`（端点代际校验）与反馈出口交给引擎。`GatewayCapabilities` 去掉 actions/direct/resources，增加 execution。观察作用域使用 Gateway 提供的 DetachedExecution，不执行 Action。
- Agents：OutputGateway、ToolDispatcher、ActionDispatcher 与 AgentGatewayCapabilities 改用 `ActionExecutionEngine`；Agent→Action 的 Invocation 构造、授权、反馈接纳语义不变。
- App：先配置 Actions 执行引擎，再配置 Gateway；启停顺序保持 Actions 启动 → Gateway → Agents，停止相反。

生命周期：ActionsContainer 的 start/invalidate/setForeground/stop 驱动引擎的准入、暂停与 join；Gateway 不再加入调度、直接调用与资源清理，只关闭 Signal 准入与传输。关闭 Gateway 准入后新调用被拒绝，已转发的工作由 Actions 取消并加入。State 节点由 gateway.scheduler/direct/resources 迁为 actions.scheduler/direct/resources。

文件迁移：Gateway/Output 下 ChannelScheduler、Channel（现 ExecutionChannel）、ActionDiagnostics、ActionExecutionLedger、ActionResultLedger、DirectExecutionDispatcher、ResourceCoordinator 迁入 Actions/Support/Shell（Scheduling、Resources、Results 子目录，随 ExecutionRuntime 目标编译）；ScheduledAction、ExecutionResult、ActionSchedulingError 迁入 Actions/Support/Contracts。经用户批准按职责整理 Actions/Support 为 Contracts、Function、Call、Shell 四个子目录，Gateway/Output 的三份 README 合并为 Shell/README.md 与 Gateway/README.md；ChannelSchedulerTests 迁入 Tests/Actions/Execution，GatewayContainerTests 中的执行用例迁入 Actions 测试。

文档同步：Gateway、Gateway/Input、Actions、Actions/Support、Actions/Support/Contracts、Agents、Agents/Support、App/Composition、总体设计、Concepts/Architecture、Container-Reflexivity 验证记录、Tests README、Xcode 工程导航。验收：`./scripts/check.sh`、`./scripts/build-ios.sh`；设备专项不受本次影响，也不由工程检查替代。

## 20. 内存警告：PlatformKit 外部 Signal，App 组合层消费

审计发现系统内存警告绕开了 SignalListener：SpeechPerception 的 VoiceInteractionSession 直接用 NotificationCenter 监听 UIApplication 内存警告，经 AgentContainer 的 memoryPressure 闭包调用 ModelContainer.handleMemoryPressure。该事件不需要 Agent 理解或业务决策，却依赖语音会话是否已创建，会话未启动或已停止时姿态、本地 ASR 等 releaseWhenIdle 模型得不到释放机会；它还让 Agents 持有无关的原生通知和模型回调。

决定：内存警告是 PlatformKit 拥有的原生状态事实，由 App 组合层把它连接到 ModelKit 的释放入口，不进入 Agents 或 Gateway。

- PlatformKit/Core 新增原生内存警告源（NativeMemoryWarnings），仅在 iOS 注册 UIApplication.didReceiveMemoryWarningNotification，复用 NativeInputBroadcast 的 latest 策略，警告合并为每个订阅者最多一个待处理值。PlatformContainer 增加 `listenMemoryWarnings()`，返回 `StateSignalListener<MemoryWarning>`（producer 为 platform.system.memory）。观察随根 start 注册、随根 stop 结束，不随前后台 invalidate 关闭，因为后台同样会收到警告；根未启动或已停止时订阅显式失败。
- App/Composition 新增 MemoryPressureRelay：拥有唯一订阅及其处理任务，每次警告调用 ModelContainer.handleMemoryPressure；订阅失败通过 ContainerFailureChannel 上报；stop 取消订阅并加入任务。ModuleRegistration 注册 `memoryPressure` 托管服务，依赖 platform 与 model，continuesInBackground，先于二者停止。relay 随 ServiceFactories.Services 按作用域重建。
- Agents 删除 AgentContainer 的 memoryPressure 参数及 VoiceInteractionSession 的内存警告任务、通知监听和 UIKit 依赖；Agents 不再接触该信号。
- ModelKit 行为不变：handleMemoryPressure 仍只尽力卸载声明 releaseWhenIdle 的空闲模型，不等待也不取消推理。

受影响文件：PlatformKit/Core（新文件、README）、PlatformKit/PlatformContainer.swift、App/Composition（MemoryPressureRelay、ModuleRegistration、ServiceFactories、README）、Agents/AgentContainer.swift、Agents/SpeechPerception/VoiceInteractionSession.swift、Tests/Agents/Core/AgentContainerTests.swift，并同步 PlatformKit、Agents、App 的 README 和总体设计。无新目录、模块或依赖。回归覆盖：警告被订阅者收到并合并、根未启动/停止后订阅失败、relay 每次警告调用一次释放且 stop 后不再调用。真实设备的内存警告释放效果仍需独立验收，本次工程测试不能代替。

## 20. Agent 内部控制函数迁入 Agents（useControls）

问题：`task.start`、`task.end`、`task.send`、`loadSkills`、`releaseSkills` 在 BasicSkill 里登记为 Control Channel 的 Action，实际经 Gateway 调用 Signal 进入 Actions Shell 排队，再由 `TaskControlCapability` 回调 Assistant 执行；`task.send` 随后又经 AgentMessaging 第二次进入 Gateway。Actions 在其中不产生任何设备或业务效果，只是借用排队，形成 Actions 回调 Agents 的回环。按仿生设计，Signal 和认知控制是体内行为，不属于可表现的 Actions。

分类（模块所有权）：
- 可表现行为（相机、语音、机械臂、窗口、作品库）：Actions，经 Gateway 与 Shell。
- 认知控制（上述五个函数）：Agents，Agent 内部处理，不经 Gateway 和 Shell，不属于任何 Channel。
- 内部 Signal：Gateway，不是函数。

`wait` 是成对标签的语法规则，继续由 FunctionTokenParser 识别，不经 JSON 登记；其说明与示例从共享 OutputProtocol 迁入 BasicSkill 的 Instructions。BasicSkill 因此成为这些规则、控制调用的唯一教学位置。

Skill.json：新增列表 `useControls`，元素为 `{path, alias}`，与 `useActions`、`useStates`、`useInstructions` 并列，不带 `channel`。BasicSkill 的五个控制调用从 `useActions` 移到 `useControls`；`startListening`、`stopListening` 是真实 Speech Action，保留在 `useActions`。Skill 解码保持严格键集合，`useControls` 最多 16 项，路径唯一且不得同时出现在 `useActions`。加载、提示词和有效快照与其他 Skill 相同；BasicSkill 是基础 Skill，本来不可释放，不新增机制。

声明：控制函数的参数与文案仍用中立的 `ActionDeclaration` 描述，由 Agents 持有（`AgentControls`），地址沿用 `Agent.Task.*`，以复用 FunctionCopy 本地化文案；`AgentFunctionCatalog` 新增 `controls`，与 `declarations`、`localTools` 的地址互斥。Actions 不再声明这些函数，也不再注入。

生成与路由：
- AgentCore 的 `CapabilityRegistry` 新增 `controls`（`ControlRegistration`，不带 Channel），`AgentConfiguration` 接受可选的 `controls` 键。`resolveAction` 命中 controls 时产生新的 `GenerationEvent.control(ControlCall)`，不产生 `ActionCall`，也就不会进入 OutputGateway 的 Action 路径。
- 控制调用不得出现在 `<wait>` 内，AgentGenerator 拒绝并回报；其余数量约束沿用单响应 120 个调用上限。
- Assistant 把控制调用登记为整轮调用，在发射时按输出顺序串行执行，不等待其他 Channel 的 Action（与原 Control Channel 相同：全双工下 `task.end` 在生成和其他 Channel 仍运行时即可提交终态），结果经 `acceptResult` 并入整轮，反馈给模型的格式不变；无整轮上下文时同样立即执行。
- 固定调用（MemoryAgent 在新对话前结束任务）直接调用 Assistant 的控制入口，不再经 Actions。
- 旧的 `Agent.Communication.send/publish` 本地拦截（`AgentCommunicationAdapter`、`AgentConfigurations.declaration` 中的特例、`modelCommunication`）没有任何生产 Skill 登记，仅由测试使用，与本次迁移无关，保持原状，另行清理；它与 `task.send` 是并存的两条路径，应在清理时择一保留。
- 控制调用不再出现在 Actions 执行日志，只记录在 Assistant 的整轮记录与 Task 状态中。

删除：Actions/System/Task（TaskActions、TaskControlModule、TaskControlEndpoint）、Contracts/TaskControlCapability、`BehaviorProtocolBindings` 的 Agent.Task 分支及 Control Channel、`ActionEndpoints.tasks`、`CapabilityModules`/`BehaviorAssembly` 的 taskControl 参数、`AgentHostBindings.tasks`、AgentRuntime 的 `business.tasks.handler`（改为 Agents 内部的 `AssistantControlLink`）、RuntimeLog 的 Control 颜色映射；BasicSkill 与 OutputProtocol 中“Control Channel Action”“Sole-call”类说法。

受影响：Agents（AgentCore Capability/Generation、AgentConfigurations、AgentContracts、AssistantChatWorker、AgentRuntime、CapabilityCoverage）、Actions（上述删除项）、App（装配）、Resources（BasicSkill Skill.json、Instructions、OutputProtocol、ActionCatalog 模板）、UI（RuntimeLog）、文档与测试。无新目录、模块或第三方依赖。

验收：`./scripts/check.sh`、`./scripts/build-ios.sh`；测试覆盖 `useControls` 解码与互斥校验、控制调用不触达 Gateway 与 Shell、`<wait>` 内控制调用被拒绝、整轮延后结算、BasicSkill 不可释放、MemoryAgent 固定结束任务。真实模型下提示词效果不在工程检查范围内，不得标记为已验证。

## 21. Skill Channel 按互斥占用重新划分

原则：Channel 是并发概念。同一 Channel 内按任务 FIFO，上一项完成后下一项才开始；因此只有互斥或占用同一表面、设备、会话的 Action 才共用 Channel，彼此独立的 Action 使用不同 Channel 才能并行。Channel 不替代资源 permit：硬件冲突仍由 Shell 的资源声明裁决。Channel 名不是模块名或页面名。

问题：
- `Display` 同时承载字幕、表情、网页加载、窗口管理、页面导航和灵动岛，多个互不冲突的操作（如最长数十秒的网页加载与窗口移动、字幕）被迫排队。
- `Camera` 同时承载拍摄/录像与 Vision 感知，Vision 启动会阻塞拍照；`cancelCapture` 的语义是取消并 join 正在进行的拍照倒计时，而 takePhoto 在倒计时结束后才完成，二者同 Channel 时取消必须等拍照结束，等于失效。
- `System` 将蓝牙设备控制与模型资源下载混放；`Query` 将互不相干的只读查询（会话历史、模型清单、Provider 设置、蓝牙状态）串成一条队列。

新的划分（Skill.json 为准，同一 path 在多个 Skill 中保持相同绑定）：

| Channel | 内容 | 互斥依据 |
| --- | --- | --- |
| `Speech`、`Display`（运行时固定） | 语音输出；字幕、回复等待与表情 | 同一扬声器；同一回复展示面 |
| `ListeningControl`（BasicSkill）、`Listening`（运行时固定） | startListening/stopListening；感知更新 | 同一聆听会话 |
| `Robot` | NexArm 全部动作 | 同一机械臂 |
| `Camera` | Camera.Capture/Video 全部动作，除 cancelCapture | 同一相机会话 |
| `CameraCancel` | cancelCapture | 取消不得排在被取消的拍照之后 |
| `Vision` | Camera.Perception 的 open/close/flip/retry | 感知流与拍摄会话独立，冲突由资源 permit 裁决 |
| `Window` | UI.Navigation.open 与 UI.Window.* | 窗口布局 |
| `Island` | UI.Island.setPresentation | 灵动岛 |
| `Web` | Web.browse/snapshot/inspect/navigate | 网页会话，加载耗时长且与窗口、字幕无关 |
| `Device` | Bluetooth.control 与 Bluetooth.readStatus | 同一蓝牙设备会话，状态读取在控制提交之后 |
| `ModelResources` | download/cancel/snapshot | 同一模型传输队列 |
| `History` | History.list/read | 会话历史 |
| `Provider` | Provider.readSettings | Provider 设置 |

表情（ExpressionInteraction）保持在 `Display`，与字幕同属回复展示面；`Query` 与 `System` 不再使用。同时存活的 Channel 名不超过 16 个：以上共 15 个，且并非所有 Skill 同时加载。

不变：固定运行时 Channel（`Speech`、`Display`、`Listening`）、Shell 的 Channel 语义与上限、原生 Tool 不使用 Channel。

受影响：Resources/Skills 各 Skill.json（channel、revision）及 Instructions（en/zh）中的 Channel 表述、Skills 与 Agents 与主 README 的 Channel 描述、RuntimeLog 的 Channel 颜色、断言 Channel 名的测试。无新目录或模块，无 Swift 调度逻辑变更。

验收：`./scripts/check.sh`、`./scripts/build-ios.sh`；新增测试确认各 Skill 的 channel 划分（cancelCapture 与 takePhoto 不同 Channel、Vision 与 Camera 不同、Window/Web/Display 互相独立）及总 Channel 数不超过 16。真实模型对新目录的编排效果不在工程检查范围内，不得标记为已验证。

## 22. 控制函数归属与 AssistantChatWorker 按职责拆分

事实：当前只有 Assistant 的 baseSkills 含 BasicSkill，因而只有 Assistant 注册并执行 `useControls`；Photographer、Memory、Writer、ApplicationControl 的 baseSkills 不含 BasicSkill，是无 Task/Skill 状态的专业角色。`task.start/end/loadSkills/releaseSkills` 变更的是宿主自己的 Task 记录、对话和 Skill 状态，`task.send` 向对等 Agent 发送信号。

归属决定：
- 契约通用：声明、`AgentControl`、注册、`resolveControl`、`permits`、`GenerationEvent.control` 属于 Agents/Support，任何会话型角色可通过 Skill 的 `useControls` 使用。
- 执行跟随状态所有者：控制修改宿主自己的状态，因此由持有该状态的 Agent 执行；不新增只有一个实现者的协议。若出现第二个宿主，再把任务生命周期（`controlLocalTaskAndSkills` 的状态事务部分）上移为 Support/Context 中与 `AgentTaskSkillState` 并列的机制，并引入宿主协议。
- 声明集中：五个控制的声明统一放 Support/AgentControls.swift，移除 `Support → Assistant` 的反向引用（当前 `AgentControls.all` 引用 `AssistantControls.all`）；`sendMessage` 的声明从 Support/Communication/AgentTasks.swift 并入，通信协议声明仍留在原处。
- `AgentControl.operation` 由字符串改为 `AgentControlOperation` 枚举（startTask、finishTask、loadSkills、releaseSkills、sendMessage），`controlTask` 对其穷尽 switch，声明与执行不再靠字符串对应。

AssistantChatWorker（4051 行，按职责拆成 Assistant 目录内的同名 extension 文件；存储属性、init 与 Registration 留在主文件）：

| 文件 | 内容 | 约行数 |
| --- | --- | --- |
| AssistantChatWorker.swift | 接口、状态与依赖（存储属性）、Registration | 650 |
| AssistantChatLifecycle.swift | 启停、恢复、暂停、清理 | 190 |
| AssistantChatInput.swift | 输入处理、handleText、批处理、drain、beginReplyTurn（本次不再细分） | 720 |
| AssistantChatGeneration.swift | generate、generateInLanguage、finishBatch、settleRound、executeRound、completeRound | 640 |
| AssistantChatFeedback.swift | 整轮结果与反馈：persistFeedback、acceptPendingFeedback、publishPendingResults、enqueue*、acceptResult、文本辅助 | 290 |
| AssistantChatEmission.swift | emitAction/emitFunctions/emitPlayback、collect、consumeActionText/NativeTools、emitImmediate、emit/emitFailure | 520 |
| AssistantChatTaskCommunication.swift | communicate、modelCommunication、receiveTask*、委派与 forwardDirectedInput、sendTaskMessage/deliverTaskMessage/receiveTaskMessageRejection | 480 |
| AssistantChatWriterEvents.swift | receiveWriterEvent/Completion、writerFacts、Writer notice 队列与播放 | 220 |
| AssistantControls.swift | `executeControl`、`controlTask`、`controlLocalTaskAndSkills`、`completeForegroundTask`、`AssistantControlLink` | 210 |
| AssistantChatStatus.swift | Context、Observability：prepareSignal、status、residentContext、effectiveCapabilities、decisionMetadata | 200 |

约束与风险：extension 在其他文件不能访问 `private`，涉及成员改为模块内部可见；不改变行为、actor 隔离与顺序语义，不新增目录或模块。需同步 Package.swift 与 pbxproj 的文件登记、boundary checker 中直接读取 AssistantChatWorker.swift 文本的检查（约 1434、1783 行）以及 Assistant README 的文件职责。

验收：`./scripts/check.sh`、`./scripts/build-ios.sh`；无新行为，现有测试不应变化，新增或调整仅限控制 operation 枚举与声明位置。

决定：控制的执行暂留 Assistant（目前唯一宿主），出现第二个宿主再上移；`AgentTaskSkillState.control` 仍以模型别名字符串为入参，未改为枚举。

修订：control 的执行不抽成宿主协议的通用库。Task、Skill、消息管理与 Assistant 的轮次、历史、任务记录和通信策略高度互相依赖，强行拆成按能力划分的宿主协议会把一个内聚的状态机切散，且目前只有 Assistant 一个宿主。保持高内聚：声明、解析、路由等机制在 Support，执行与它依赖的状态一起留在 Assistant；若将来出现第二个宿主，再按实际需求提取。

## 23. Control 作为 Assistant 内置函数库，移出 Skill 配置

决定：Task、Skill 与消息管理的 control 是 Assistant 的内置函数库，不再由 Skill 声明 `useControls`。别名、声明和执行都在 Assistant 内，随 Assistant 状态高内聚；Skill 只配置 Action 与 Tool。

库（Assistant/AssistantControls.swift）：`AssistantControl`（alias、`ActionDeclaration`、`AgentControlOperation`）、`AssistantControls.all`、按 path 查找，以及执行扩展（`executeControl`、`controlTask` 等）。解析器把标签别名解析为 `ControlCall`（path 与参数）后，由库的 path 查找直接得到 operation，不再经 `AgentControls`（Support）转手。

注册与暴露：
- `ControlRegistration` 保存规范 `ActionDeclaration`，可按当前语言重新本地化；JSON `controls` 配置通道删除。
- `AssistantContextState.runtimeCapabilities` 把库的注册加入固定能力（`CapabilityRegistry.adding(controls:)`）。`AgentSkillLoader.registry(_, fixed:)` 沿用 `fixed.controls`，并在中文语言下用 FunctionCopy 重新本地化。
- 因此 Assistant 的 control 始终可用，不依赖 BasicSkill 的加载状态；其他 Agent 没有 control。
- AgentContracts 的静态检查（control path 与已声明 Action/Tool path 互斥）改引用库。

删除：Skill schema 的 `useControls` 与 `AgentConfigurations.Control`、`AgentSkillLoader.controls`、`AgentConfigurations.declaration/registry` 的 controls 参数、AgentConfiguration 的 `controls` 键、Support/AgentControls.swift 及其 pbxproj 与 checker 登记。BasicSkill 的 Skill.json 去掉 `useControls`，revision 递增；Instructions 不变。

受影响：Agents/Support（Skill 解码、Loader、Configurations、Core Capability）、Assistant（库与固定能力）、AgentContracts、Resources/Skills（BasicSkill、README）、相关 README、boundary checker 与 pbxproj、测试（control 的来源由 BasicSkill 改为 Assistant 固定能力，`useControls` 断言删除）。无新目录或模块。

验收：`./scripts/check.sh`、`./scripts/build-ios.sh`；测试覆盖 Skill 含 `useControls` 被拒绝、Assistant 固定能力含五个 control 且中文本地化、其他 Agent 无 control、`<wait>` 内 control 被拒绝仍成立。真实模型下提示词效果不在工程检查范围内。
