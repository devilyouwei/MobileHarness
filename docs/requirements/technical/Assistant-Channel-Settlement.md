# Assistant 按执行轮次结算后提交下一批输入

2026-11-12。真机对话的 SQLite 请求记录显示，同轮 Camera Channel 的两个回执仅相差约 2.5 毫秒，却先后启动独立推理并重复生成重拍动作。用户要求以所有 Channel 的执行终态作为下一次推理边界，并将等待期间收到的用户输入纳入同一批。

## 运行边界

- Gateway 保持当前 Channel FIFO、跨 Channel 并行及调用终态投递。复用现有 `GenerationRoundResult`，等待 Channel 执行和结果投递结束。模型流结束时封口，Assistant 保留挂起轮的授权与身份，下一批主模型请求仍等待结算。
- `AgentChatWorker` 保留既有 Signal 接纳、容量、Action 结果与原生工具配对。挂起时只允许处理执行结算入口。结算记入原轮历史后，从统一队列冻结同会话的 Action、工具和用户输入。用户输入仍可在等待时进行有界快决策，明确打断走既有取消及加入清理路径。
- 结算开始时记录同会话已在接纳或分类中的输入身份，等这一组处理完毕再冻结队列。之后到达的候选不延长该等待。真实失败保留原回执，纯取消不产生模型反馈。暂停与关闭继续退役相应执行和输入。

## 验证

更新共享 Chat、Assistant、Agents 及总体技术文档。回归覆盖单轮多 Action 合批（含异常）、用户等待、原生工具与 Channel 合批、取消清理和队列容量。运行定向测试、完整检查及 iOS 构建。

## 打断后等待续说（2026-11-22）

成功认领同会话打断时立即阻止下一批派发，并取消及加入 LLM、Action 和播放清理；清理成功完成后才开启 1200ms 单调时钟窗口，停止耗时不消耗用户续说空档。窗口中或清理期间已确认的新语句须等待 ASR 收尾并成功进入 Assistant 普通队列。最后一个在途语句收尾后重新留出完整 1200ms 空档，期间再次起声则继续等待并在收尾后重新计时；窗口结束且没有在途语句，才冻结下一批。语句失败、空结果和采集关闭同样解除对应语音等待并留出空档；会话关闭、暂停、停止或清理失败取消屏障和定时器，异步清理返回不能重建已退役的等待；旧语句回调不能重置当前窗口。保持原有队列容量、普通输入及独立会话行为；不阻止已取消轮次的结算。

SpeechPerception 的 `SpeechPerceptionAgent.swift` 在确认起声、结束及失败时通过 AgentRuntime 绑定的内部状态通知 Assistant；final 发布与目标入队异步，需区分发布、实际入队和失败，不能仅凭 VAD 结束解除屏障。`AssistantChatWorker.swift`、`AssistantChatInput.swift`、`AssistantChatLifecycle.swift` 管理有限等待及清理；`AgentGatewayAssembly.swift` / `InputGateway.swift` 的既有发布失败路径须保证语音投递拒绝可解除对应等待并保留错误。保持现有认证与 Gateway 发布，不建立绕过 Gateway 的文本传递。移除 Assistant `speechInterruptionID` 和 SpeechPerception 的确认路径；`speechEndpointActivity` 仅返回同会话回复工作或播放状态，VAD 在活动期间使用 16 窗、其他时间使用 25 窗，保留播放期间起声阈值。

`AgentGatewayPorts.swift` 的装配契约传递发布终态回调；`AgentRuntime.swift` 通过既有 AssistantControlLink 绑定失败通知。`SpeechPerceptionContainer.swift` 同时将发布前输出失败报告给感知角色，防止有界输出失败后留下等待。`Assistant/Controls` 与 `Agents/Support` 的技术文档同步装配接口。

更新 Assistant、SpeechPerception 及总体 README；在现有 `InputDecisionTests.swift`、`GenerationRoundTests.swift`、`VoiceTests.swift` 和 `CommunicationTests.swift` 覆盖窗口、续说 final 合批、期间连续语句、延迟投递、无语音、投递终态、失败、空结果、停止、旧代及端点规则。定向测试、`./scripts/check.sh` 和 `./scripts/build-ios.sh` 分别记录；真实模型和物理设备验收另计。

实施与验证结果见[验证记录](../../validation/Full-Duplex-Playback-Admission.md#打断后等待续说2026-11-22)；原生界面检查缺少完整结束记录，真机全双工验收尚未执行。

本轮调整限于 `AssistantChatWorker.swift` 的屏障建立、清理后计时和最后语句收尾重置；复用 `AssistantExecutionSession.performInterruption` 的完成边界，不修改 SpeechPerception 的 VAD 参数或 Gateway 文本投递。`InputDecisionTests.swift` 增加慢清理、续说收尾后的最小空档、空档中再次起声和清理期间生命周期退役回归。同步 Assistant/Workflow、Assistant 和总体技术说明，分别执行专项、完整检查及 Simulator 构建；真实模型和真机验收另计。

用户要求将打断后的等待及续说收尾后的空档从 800ms 扩大至 1200ms；只调整 `AssistantChatWorker.swift` 的等待时长，维持既有起声确认、ASR final 入队合批、失败清理和 VAD 端点。更新 `InputDecisionTests.swift` 的实际派发时间断言及等待中的语音覆盖，更新 Assistant 和 Workflow 技术说明，分别记录专项测试、工程检查和 Simulator 构建。窗口仍依据已确认的起声通知，音频处理延迟或起声确认跨越窗口的竞态不在本次参数调整中解决，真机体验另行验收。

## 打断后一次性语音窗口探测（2026-11-22）

以 SpeechPerception 已完成 VAD 判定的 40 个 512 样本窗口（16kHz，约 1280ms）替代 Assistant 的 1200ms 定时等待。只计清理完成后采集的音频，采集时间和 VAD 处理水位须对齐，不得因处理积压或窗口起声候选未确认而提前放行。边界出现尚未确认的起声候选时，等其确认或消退；已确认语句转为等待正常 VAD 结束及 final 实际入队，完成后立即放行，不重开窗口，也不等待原窗口剩余时间。清理期间已确认的语句也适用；多个已确认语句均须结算。空结果、识别/投递失败显式处理并解除对应语句，采集关闭或 VAD 不可用须显式报告且退役探测，不能永久等待。外部控制及结算继续处理，其余输入沿既有队列，探测不随外部 Signal 延长。

实现涉及 `AssistantChatWorker.swift` 与 `AssistantChatInput.swift` 的屏障状态及释放，`VoiceActivitySegmenter.swift`、`SpeechBoundaryPolicy.swift` 和 `SpeechPerceptionAgent.swift` 的窗口及起声候选观察，`AgentRuntime.swift` 的身份安全装配，必要时使用现有语音容器的采集生命周期接口。更新 Assistant、Workflow、SpeechPerception 和总体 README；在现有 Assistant/InputDecisionTests 和 SpeechPerception/VoiceTests 测试清理前音频、40 窗、边界候选、音频积压、确认后立即等待 final、多个语句、空值/失败、采集关闭及旧代回调。跑定向回归、`./scripts/check.sh` 和 `./scripts/build-ios.sh`；真实模型及物理设备另行验收。

只在无人声探测阶段保留 10 秒失效看门狗：VAD 未能推进时报告观察停滞并退役屏障，而不当作 40 窗静音成功；确认人声后取消看门狗，ASR 按既有完成和失败契约收尾。采集代身份隔离窗口及停止通知；采集或识别不可用显式报错。

工程结果及原生回调采集时间精度限制见[验证记录](../../validation/Full-Duplex-Playback-Admission.md#打断后-40-个语音窗口)；物理设备验收和回调边界精度仍待验证。

## Decision 最新候选优先（2026-11-22）

用户批准 latest-wins：在 `AssistantInputDecision.swift` 内调整 AssistantDecisionQueue，新候选取消当前分类，只对最新候选启动后续推理；中间候选和被替代的当前候选不提交打断信号，以 `superseded`、无布尔值和无模型失败结算证据。普通语义队列中的全部输入不变。保留最多 32 条待结算记录（含当前项）的拒绝式容量限制，但等待推理的候选只有最新一条。

AssistantInputDecision 保留真实原生 worker 所有权；取消或超时只退役其结果，不释放仍运行的模型。每个模型通道最多一个原生 worker 和一个最新等待尝试。后继尝试取消旧 worker，等其实际退出才启动；清理等待计入后继尝试的既有截止时间，过期显式超时，不能假成功、重入、自动换模型或强制卸载。定时器、取消和完成均按尝试身份隔离，旧回调不能取消或结算新尝试。模型切换、维护与停止继续加入真实清理；关闭会话取消对应当前分类。

在现有 InputDecisionTests.swift 覆盖连续替代、旧结果不触发打断、全部输入保留、慢清理后恢复、等待超时不重入及取消身份隔离。同步 Input/Assistant README 和测试说明；执行定向回归、工程检查和 iOS 构建。真实 Laya 和真机卡住仍需阶段证据；latest-wins 不承诺终止不响应取消的 CoreAI 原生调用。

RuntimeLogState/RuntimeLogView 和共享本地化资源将被替代的记录呈现为独立 `superseded` 路径及状态，不归为失败，也不伪装成成功布尔值；在 ExecutionLogTests.swift 验证失败筛选仍保留真实超时、排除被替代的记录。同步 RuntimeLog README。

实现及工程证据见[验证记录](../../validation/Full-Duplex-Playback-Admission.md#decision-最新候选优先)。真实 Laya 与物理设备取消/恢复验收尚未执行。
