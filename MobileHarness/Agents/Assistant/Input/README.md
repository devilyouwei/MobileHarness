# Assistant input

Assistant input admission, batch text, quiet wake and interruption contracts. Input prompt resources are under [Resources/Agents/Assistant/Input](../../Resources/Agents/Assistant/Input).

| File | Responsibility |
| --- | --- |
| [AssistantChatInput.swift](AssistantChatInput.swift) | Input admission, text handling, prepared batches, interruption speech-wait gating, queue drain and reply-turn start. |
| [AssistantInputBatch.swift](AssistantInputBatch.swift) | Trusted source timeline, batch text, source-line markers and input prompt access. |
| [AssistantInputDecision.swift](AssistantInputDecision.swift) | Selected Decision routing and bounded binary inference for quiet wake and interruption. Also owns the interruption snapshot and queue. |
| [AssistantInterrupt.swift](AssistantInterrupt.swift) | Public interruption target, signal and result contracts. |
| [AssistantListeningSignal.swift](AssistantListeningSignal.swift) | `agent.listening.mode.v1` and `agent.reply.activity.v1` messages and the worker's publication of them. |
| [ListeningCoordinator.swift](ListeningCoordinator.swift) | Handler of the `listening` Trigger: published mode, `full` capability check, `quiet` exit judgment scheduling and record. |
| [QuietExitJudge.swift](QuietExitJudge.swift) | `quiet` exit judgment: literal rule or one boolean request over the latest sentence and optional wake agreement. |

## Decision scheduling and cleanup

The interruption prompt renders the frozen reply and latest user input into a localized sentence, followed by one question about whether the user intends to interrupt. The spoken reply is empty until natural-language output is available. ModelKit binds the sentence and question to the provider's binary readout. Quiet wake has its own templates.

AssistantDecisionQueue retains at most 32 unsettled jobs, including the current job; overflow rejects classification without removing ordinary input. New admission cancels the current classification and replaces the waiting inference candidate. The serial settlement worker records superseded jobs with `signalStatus = superseded`, no boolean and no model failure; only the newest candidate is inferred. A result already submitted to the interruption entry is not retroactively revoked. Closing a session removes its jobs and cancels its current classification; pause/stop cancels and joins the queue worker.

AssistantInputDecision reads the same saved Decision choice for both entry points and owns at most one actual inference worker and one waiting attempt per local/cloud channel. New attempts cancel the previous worker and retire its result, but cannot start until that worker exits its complete ModelKit cleanup. Waiting consumes the new attempt's existing deadline; expiry explicitly reports timeout, never overlapping native calls or switching providers. Attempt IDs fence timeout, cancellation and completion so stale callbacks cannot affect successors. Model maintenance/switching and root shutdown join the retained inference worker. CoreAI cancellation remains cooperative: this scheduling cannot forcibly terminate a stuck native call.

## Speech activity and listening Signals

The Assistant is a subscriber and publisher; it neither constructs nor calls the perception role.

| Signal | Direction | Handling |
| --- | --- | --- |
| `perception.speech.activity.v1` (`perception.speech.activity`) | SpeechPerception → Assistant | Validated by source, topic, incarnation, contract and version, then handled before ordinary admission without queuing or Decision. `captureStarted`/`captureStopped` carry the capture generation (a new generation drops earlier utterances and candidates and fails a running probe); `onsetStarted`/`onsetCleared` track a pending onset candidate; `onsetConfirmed` tracks an utterance ID (at most 32, overflow rejects) until its final text is admitted or `utteranceEnded`/`utterancesCleared` retires it; `duplexSupport` reports echo cancellation; `ended` clears speech state and returns `listening` to its default. |
| `agent.reply.activity.v1` (`agent.reply`) | Assistant → SpeechPerception | Reply work, unsettled rounds or playback select the 512 ms instead of 800 ms silence endpoint. The Signal also carries at most 32 native playback intervals for capture-time onset thresholds. Activity, reply ID or playback changes trigger a coalesced publication. Each `captureStarted` requests the latest snapshot again. |
| `agent.listening.mode.v1` (`agent.listening`) | Assistant → SpeechPerception | Published after every accepted `listening` change and again on each `captureStarted`, because Signals are not replayed. Publication failure is reported, not retried. |

Speech facts are low-rate and take the Gateway control lane. They carry no PCM or text.

### Post-interruption probe

All accepted full-duplex interruptions keep existing onset candidates and tracked utterances. The reply activity Signal requests observation from the admission instant. SpeechPerception replies for the current capture after 64 scored VAD windows. Confirmation may arrive while cleanup or ASR is still running. Continuous speech in an already confirmed utterance keeps the same utterance ID and awaits its complete transcript. Automatic dispatch also requires confirmed cleanup, settled utterances and resolution of any pending onset candidate. A stopped or replaced capture restarts the count when capture resumes. Pause, stop and session closure retire the observation.

### `listening` and `quiet`

Every quiet episode can carry a wake condition from the model's `state.set` call. For `literal:<phrase>`, the judge checks whether the phrase occurs in the latest ASR sentence and records the result as `literal`. Other conditions use JSON with the condition and latest sentence. An episode without a condition uses the default invitation prompt and plain ASR text. A newer sentence or a replacement condition retires the previous judgment. Leaving quiet clears the condition from State.

ListeningCoordinator is the `listening` Trigger handler and the only writer that ends `quiet`; AgentRuntime creates it and binds the reply cancellation, host write, mode publication and release operations. `full` is rejected when the current capture reported no echo cancellation; with no capture yet it is accepted, and a later unsupported report writes `half` and surfaces the reason, and a later supporting capture restores `full` unless the mode was changed explicitly in between. `full` is the default, including after a session ends. Entering `quiet` records the mode to return to. A host write joins the existing conversation interruption before entering. A model write publishes the mode within its own round, then cancels audio handles owned by that input. The generation worker settles the control and the round through its ordinary completion path.

In `quiet`, final ASR goes to QuietExitJudge (latest sentence ≤ 512 characters, default and conditioned questions in `Resources/Agents/Assistant/Input/QuietExit*.json`). The judge submits one `noul` request to the same Settings-selected Decision service as interruption. The configured provider can be native or Chat-backed and uses the same request deadlines and cancellation. A newer sentence replaces the pending judgment, and mode/episode and request identities fence stale results. Assistant shutdown retires the judgment and joins the shared inference service.

A successful true result restores the previous mode and admits the same input as ordinary user speech. A false result or request failure leaves the Assistant quiet. Three consecutive failures are reported once. Current results and failures are recorded in [listening_dialogs](../../../Storage/Database/ListeningDialogs/README.md). The perception role publishes final text in every mode and adopts the published mode for its duplex policy and Island title.

## 流式关键词快停

`ReplyActivitySignal` 发布当前同会话回复 ID。SpeechPerception 的
`AssistantInterrupt` 必须带同一回复目标与已确认语句 ID，并通过全双工、会话与
目标校验，使用和其他来源相同的停播入口。快停成功后，同一句最终 ASR 文本继续正常
入队，其打断 Decision 被去重。模型缺失、无命中和未成功发送时保留最终文本的原有判定。
全双工活动语音会话的完整转写恰好为 `stop` 或「停下」时，模型给出否定或失败的结果后，
也可通过同一回复目标围栏停播。日志和历史仍记录模型自身的结论。
