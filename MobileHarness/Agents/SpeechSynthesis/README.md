# SpeechSynthesis

## 函数与通信注册清单

✅ 以下为当前实现的完整注册清单。模型权限来源：[配置文件](SpeechSynthesis.agent.json)；内部权限来源见各行链接。参数后缀 `?` 表示可选，`—` 表示无参数或无 Channel。

模型 Action 通过 Action call 调度；模型 Tool 通过原生函数调用取得结果。InternalAction / InternalTool 是代码固定流程的权限，不会自动进入模型函数目录。同一函数跨 Agent 注册，或在同一 Agent 同时提供模型入口与内部入口，属于授权复用；模型 Action 和模型 Tool 不重复注册同一路径。

### 模型可调用函数

无模型 Action 或模型 Tool。

### 代码固定流程的内部函数

无内部函数注册。SpeechSynthesis 直接使用注入的 SpeechSynthesisCapability 合成并保存音频引用；播放由原输出 Agent 注册的 Speech.Playback.speak 执行。

### 通信输出权限

这些是 CommunicationAction 的授权契约，不是额外的原生 Tool。publish 单向广播，不等待接收方回包，不因接收方拒绝/错误影响发送方；send 返回接纳回执，接纳与任务完成分别记录。模型 send 仅暴露上述 task.* 权限；语音合成、取消及事实广播由代码固定流程发出。

无 publish / send 输出权限。


Purpose: a shared text-to-audio Agent, independent of Assistant and playback Channels. Owns a FIFO request queue and one serial ModelKit synthesis worker. Configuration and directed permissions use JSON v6.

```mermaid
flowchart LR
    Source[Any authorized Agent] --> OG[OutputGateway]
    OG --> IG[InputGateway]
    IG --> Inbox[32 queued/admitting requests]
    Inbox --> Worker[One serial synthesis worker]
    Worker --> Model[SpeechSynthesisCapability]
    Model --> Store[StorageAudio PCM store]
    Store -->|failure / reply cleanup / cancellation| Worker
```

## 输入、订阅与输出契约

以 [SpeechSynthesis.agent.json](SpeechSynthesis.agent.json) 和 [SpeechSynthesisAgent.swift](SpeechSynthesisAgent.swift) 为准；公共信封、回执含义见 [Agents 输入输出约定](../README.md#输入输出文档约定)。`communication.subscriptions = []`：只接收明确指定目标为 `speechSynthesis` 的定向消息。任何获准发送的 Agent 都可提供文本，服务不依赖 Assistant 身份。

| 接收方式 | contract / version / kind | payload 数据标准 | 接纳与处理 |
| --- | --- | --- | --- |
| 定向 send | `speech.synthesize / 1 / observation` | `.observation(.speechSynthesis(SpeechSynthesisInput(audioID: UUID, text: String, locale: String)))`；audioID 是请求方生成的唯一句柄；text 去空白后须非空、最多 2000 UTF-8 字节；locale 为 `auto / zh-CN / en-US`。完整消息编码最多 16 KiB。 | 校验未过期、类型与内容、队列容量和句柄唯一性；先在 StorageAudio 注册句柄，再返回接纳回执。按实际接纳顺序串行合成。 |
| 定向 send | `speech.cancel / 1 / observation` | `.observation(.cancelSpeech(audioID: UUID))`；只含待取消句柄，完整消息编码最多 16 KiB。 | 句柄所有者必须匹配绑定发送方、session 和原父输入。取消队列或活动任务；不占合成队列。 |

输入 `AgentInput` 带 sessionID、turn 和 InputMetadata。发送方用 `parent` 建立因果关系；StorageAudio 的所有权键为 `source + sessionID + (parentID ?? input.id)`。队列最多 32 个等待/接纳中的合成请求，满时明确拒绝；每项从 worker 开始执行起限时 60 秒，不包含 FIFO 排队时间，也不是从 speak 开始等待起计时。生产 PCM 空读没有独立超时。共享缓存另限制最多 32 个存活句柄（含排队、合成中、待播和播放中）；达到任一容量限制即明确拒绝。`DeliveryReport.delivered` 只表示上述接纳成功，不表示 PCM 已产生。

### 输出、publish 与 send

| 方向 | 当前数据标准与消费者 |
| --- | --- |
| Agent 输出流 | 无业务 `OutputEnvelope`、ActionCall、ToolCall 或 control 输出；`outputs` 流仅为统一 Agent 生命周期接口，停止时结束。JSON 的 `actions` 为空对象，`tools` 为空数组。 |
| publish | `communication.publications = []`；不广播合成结果或进度。 |
| send | `communication.sends = []`；不向其他 Agent 定向发消息。 |
| 本地存储结果 | 用同一 audioID 在 StorageAudio 的 `SpeechAudioStore` 中写入单声道 Float32 PCM 帧，成功后标记完成，失败/超时/取消则标记错误；这不是 publish/send。SpeechPlayback 在 Action 到达时用 audioID 等待并消费，播放结果不由本 Agent 回传。 |

PCM 格式在一项请求内保持一致，帧 sequence 严格递增，流必须有 `finished` 且非空，总输出最多 8 MiB。模型或缓存错误写入对应句柄，不产生一条“成功”消息；请求方若需获知最终结果，应在消费该句柄时处理存储错误。当前不提供跨 Agent 的完成通知或持久化文件。

✅ `speech.synthesize / 1 / observation` carries `SpeechSynthesisInput(audioID,text,locale)`. Nonblank text ≤2000 UTF-8 bytes; locale auto/zh-CN/en-US. The original Agent selects semantic segments. Model adapters retain language/length adaptation under the same audioID. `PerceptionMessage` defines typed business cases, carried by Core’s generic AgentMessage without a compatibility alias.

✅ `speech.cancel / 1 / observation` carries a UUID; ownership is checked against the directed sender, session and parent input. No subscriptions and no Assistant-specific source assumptions. Reception validates and reserves the handle before returning admission; it never awaits inference or capacity.

✅ Synthesis is serial in actual reception/admission order, regardless of Channel eligibility. The 60-second execution deadline starts in produce, excludes queue time and ends when synthesis completes or fails; mono Float32, stable format, increasing sequence, explicit EOS, nonempty audio and 8 MiB total output are validated. The worker advances after synthesis completion/failure without waiting for playback; later text requests can queue while an earlier Action waits or plays. Cache overflow fails that request and the worker continues. Pause retains bounded work, stop cancels/joins owned work; cancellation never drops another source's request.

✅ App registers the Agent alongside Assistant; shared cache ownership is injected. No Actions, model SDK imports, playback callback or direct Agent-to-Agent calls.

❌ File output, retry, priority, replay and hardware performance acceptance remain outside this implementation.

✅ Producer failures use SpeechSynthesisError; cache/PCM failures use StorageAudio.SpeechAudioError. Scheduled consumption belongs to SpeechPlayback.

✅ Pending and completed-unclaimed audio uses reply-owned lifetime without queue/ready TTL. App clears remaining source/input handles after reply completion/cancellation, and session handles on interruption. A reply is one originating source/input within a voice session, not the entire multi-turn session. Consumed frames leave the cache immediately and each played handle is released after hardware drain; only unconsumed audio remains until owner cleanup. The synthesis execution deadline is not a cache expiry or a total playback-wait deadline. ❌ Long-sequence physical-device acceptance remains pending.

<a id="synthesis-timeout-propagation"></a>

## 合成执行超时与播放 Action 的错误传递

✅ 超时由 `SpeechSynthesisAgent.produce` 内的独立 Task 实现：请求从 FIFO 出队并开始执行时启动，默认 `executionTimeout = 60 秒`。收到 PCM 不会重置计时；合成正常完成或失败退出时，由 `defer` 取消计时任务。排队时间不计入此期限，已经合成成功的音频也不会因为后续等待播放而触发合成超时。

到期后调用 `store.fail(audioID, error: SpeechSynthesisError.timedOut)`。Agent 不直接调用播放 Action，也不发送一条超时 Agent 消息；合成与播放通过同一 audioID 对应的共享缓存传递失败状态。

```mermaid
sequenceDiagram
    participant S as SpeechSynthesisAgent
    participant C as SpeechAudioStore / MemoryLeaseStore
    participant B as SpeechAudio / BoundedMemoryStream
    participant P as App / AppleAudioIO
    participant A as SpeechPlayback / speak Action
    S->>C: fail(audioID, synthesisTimedOut)
    C->>C: retire handle and retain bounded terminal error
    C->>B: fail(error): clear unread PCM and wake reader
    C->>S: cancelJob(audioID): cancel active synthesis worker
    B-->>P: pending or next PCM read throws
    P->>P: stop playback on error
    P-->>A: propagate error and clean up
    A-->>A: throw to scheduler / Gateway
```

| 播放状态 | 收到超时后的行为 |
| --- | --- |
| 正等待首块或下一块 PCM | 缓存立即以 `synthesisTimedOut` 恢复挂起的读取，播放端停止当前播放并抛错。 |
| 正播放已提交的缓冲 | 失败不会直接回调播放器；下一次读取 PCM 时发现错误，再停止尚未播完的缓冲。已经出声的部分无法撤回。 |
| Action 尚未执行 | 后续 checkout 在终态错误记录仍保留时抛出同一错误；记录过期或被容量淘汰后报告 missingAudio。终态记录最多 128 条、默认保留 30 秒，不保留 PCM。 |

错误经 AppleAudioIO → SpeechPlayback → Speech.Playback.speak 向调度器/Gateway 传播，由既有 Action 失败和 App 回复清理流程处理。清理不会自动重新合成或重播；同一缓存句柄的首次失败会保留，后续取消不会覆盖已记录的超时。

✅ `SpeechPlaybackTests.synthesisExecutionDeadlineIsIndependentOfPlaybackDeadline` 验证 Agent 执行期限能让等待 PCM 的读取收到 `synthesisTimedOut`；延迟 PCM、显式读取期限和取消有各自回归测试。PCM 空读默认没有独立期限，硬件播放完成超时是另一项 PlatformKit 保护。

❌ 取消是协作式的：底层推理若未及时响应，worker 退出和下一项合成仍可能延迟；这不是强制终止底层计算或保证精确到 60 秒的实时机制。测试不等于真机超时听感验收。

✅ SpeechSynthesis passes the trusted directed sender string into StorageAudio; audio storage does not import AgentCore. Ownership still includes the originating session and parent input.

✅ SpeechSynthesisInput is owned by Agents/Support/Communication/SpeechValues.swift with unchanged text/locale contract and queue policy. Domain value validation is independent of AgentCore; message admission maps errors to the existing transport rejection.

✅ Synthesis owns the ModelKit.AudioFrame → StorageAudio.SpeechPCMFrame conversion, preserving bytes, format, sequence and timestamp after existing format/order validation. Storage owns its PCM types; it does not import ModelKit or Types. ❌ No playback/device preparation belongs to synthesis.

## Current error ownership

✅ SpeechSynthesisError owns timedOut and invalidOutput. Context identity, mono Float32/stable format, sequence, EOS, nonempty output and synthesis byte policy remain Agent-owned; StorageAudio validates its PCM contract separately. Producer errors pass through the store to playback unchanged. App owns localized messages.

❌ Automatic producer retry and real-device performance acceptance remain outstanding.

## Agent composition — ADR0187

✅ Agent 自有预处理、版本化结构化 Context 和 Builder 已接入；共享机制在现有 Agents/Support/Core 与 Agents 目录中。业务职责保持当前分界。函数结果按运行时捕获的执行所有者定向返回，通信投递回执只表示接纳；模型续轮不订阅自身广播。

✅ 上下文采用有界原子提交，重启将未完成工作标为中断，不重放设备动作。普通输入、反馈和控制分别接纳；所有容量或持久化失败显式返回。音视频和原生会话保持有界临时状态。

✅ 第二阶段已实现独立摄影 LLM、正式任务委派及任务定向后续输入。❌ 真实模型、原生 UI、真机语音验收仍待完成。

开发契约（输入/输出权限仍以本目录 JSON v6 和 InternalAction/InternalTool 注册为准）：

- 预处理与隔离：定向 speech.synthesis FIFO32；cancelSpeech 控制旁路，按原始 source/session/input 验证音频所有权；不发布聊天消息。
- Context Schema：SpeechSynthesisContextState：pendingAudioIDs/activeAudioID，输入/批次及完成/失败记录；音频流由 StorageAudio 的有界所有权容器保管。
- Builder 与决策：SpeechSynthesisContextBuilder 构建真实 SpeechSynthesisRequest 与 InferenceContext；一个合成 worker，独立于播放 Channel。
- 容量、取消、失败与恢复：单任务执行默认60秒。取消/停止加入合成会话并关闭音频；错误保留真实失败，Context 写入失败禁止开始依赖该状态的合成。重启清除音频句柄，不恢复播放。

设计与阶段边界见 [ADR0187](../../../docs/adr/0187-agent-composition-and-react.md)；验证见 [Validation-History](../../../docs/Validation-History.md)。

✅ ADR0187 流式能力只保留最近256条证据/消费摘要，淘汰计数可查询；原始媒体不存盘。长期运行不因感知事实累计填满普通业务档案。合成取消先验证音频所有权，成功后提交状态并加入 worker 清理；已接纳但注册失败的音频任务明确记录终态。

Implemented source organization: follow the [business source standard](../README.md#business-source-organization-standard). Agent.swift groups interface/declarations, registration, lifecycle, admission/workers, output, context and observability; Processing.swift groups State/Preprocessor/Builder and pure role policies. Shared recordSignal persists role-classified evidence atomically; the Agent still selects consumption timing, retention and business mutations.
SpeechSynthesisError and task-local failure cleanup context are co-located with SpeechSynthesisAgent; Processing contains only pure state/input/request policies.
