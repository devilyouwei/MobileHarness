# Technical concepts

## Signal → Cognition → Action

The biological analogy describes functional organization: sensing provides signals, cognitive processes interpret them, and behavior changes what can be sensed next. It is an architectural metaphor rather than a claim to reproduce biological intelligence.

| Concept | Meaning | Biological analogy |
| --- | --- | --- |
| Signal | Immutable Agent input: intent, observation, Agent message or execution feedback, carried by AgentInput. | Sensory and inter-region signals. |
| Agent | Stateful processor with a distinct role, input ownership and permitted outputs. | Specialized functional brain region. |
| Gateway | Validation, communication routing and execution coordination boundary. | Neural pathways coordinating signals and commands. |
| Capability | Typed model/device/data operation supplied to a consumer. | Processing machinery or sensory/effector capacity. |
| Action | Protocol-neutral callable business function with shared input, completion and failure rules. | Coordinated behavior. |
| ActionCall / ToolCall | Scheduled text-call and native function-call protocols over permitted Actions. Native calls may use direct or shared scheduled execution. | Alternative command pathways. |
| App / UI | Whole-system lifetime/composition and user-facing interaction. | Organism and expressive surface. |
| Storage / shared values | Retained data and shared value vocabulary. | Retained information and signal representation. |

## Communication and execution

Publication selects declared subscribers; directed delivery selects an explicit recipient. Admission means acceptance for processing rather than completed inference or behavior. Agent messages and Tool/Action results return through the input boundary.

Function Token is a mixed natural-text/XML behavior protocol, not a tokenizer token. Agents interpret it and resolve aliases before execution. A Channel is a task-local Action ordering scope. A wait group joins relevant Action work without making unrelated tasks share a global barrier. Native ToolCall bypasses Channel queues only when its binding selects direct execution; scheduled native bindings use the shared scheduler. Both enforce permission/resource checks.

A capability call is foundational processing, such as inference or data retention. A business effect, such as playback, UI presentation or robot movement, is a registered Action invoked through an authorized call protocol. This distinction keeps model computation separate from effect authorization.

## Identity, ownership and completion

Session/turn/input identity separates current work from stale output. The owner of an operation retains its resources through cleanup. Model generation completion, Action handler completion, speaker drain and rendered-frame completion are distinct milestones.

Model residency is separate from model operation ownership. A retained capability does not imply active inference, and cancelling an operation does not itself require unloading weights. Shared value types carry data rather than service lifetimes.

## Directions beyond the current implementation

Edge/cloud collaboration means explicitly selecting remote processing where provided; it does not imply automatic compute escalation. Fast/slow cognition describes complementary responsive and deliberative processes; general orchestration remains a planned direction. Embodied intelligence means behavior has observable device/environment effects; it does not establish autonomous robot safety.

[Architecture](Architecture.md) describes current collaboration. The [technical design](../MobileHarness/README.md#part-iii--key-techniques) defines cross-module flows and module READMEs define the algorithms.

The active [Signal contract](../MobileHarness/README.md#unified-signal-contract) defines the shared envelope, payload ownership, admission and feedback rules, with current implementation gaps explicitly marked.

## Agent composition — ADR0187

✅ Agent 自有预处理、版本化结构化 Context 和 Builder 已接入；共享机制在现有 Agents/Core 与 Agents 目录中。业务职责保持当前分界。函数结果按运行时捕获的执行所有者定向返回，通信投递回执只表示接纳；模型续轮不订阅自身广播。

✅ 上下文采用有界原子提交，重启将未完成工作标为中断，不重放设备动作。普通输入、反馈和控制分别接纳；所有容量或持久化失败显式返回。音视频和原生会话保持有界临时状态。

✅ 第二阶段已实现独立摄影 LLM、正式任务委派及任务定向后续输入。❌ 真实模型、原生 UI、真机语音验收仍待完成。

执行所有者（Agent/incarnation/session）、task/parentTask、Signal 因果 root/parent、decision/call 分别关联。ActionResult 按可信运行时所有者路由；TaskResult 是子任务显式报告，communication receipt 是接纳反馈。反馈旁路、普通输入 FIFO/融合/替换由各 Agent 决定。

参见 [ADR0187](adr/0187-agent-composition-and-react.md) 与 [Agents 当前设计](../MobileHarness/Agents/README.md)。

✅ [ADR0190](adr/0190-assistant-listening-and-one-way-publication.md): SpeechPerception owns listening consent and admission policy through fixed Actions; interactive Agents publish reply occupancy and App executes native/playback barriers. External facts publish one-way, internal send retains admission receipts, and recoverable speech errors do not stop recording. Physical recording stops on user-off/native interruption; policy pause suppresses recognition input while preserving capture.

## Frontend and Agent backend

✅ Signal/Action describes the Agent boundary, not every UI event. Like a web frontend, UI owns local navigation, drafts, filtering, selection and rendering. Explicit data/resource/history/camera/device requests publish directly to their owning Agent. Conversation enters Assistant, which may delegate actual tasks. Agent-initiated presentation still uses authorized UI Action functions over the same presentation state; local touch interaction does not create a backend task merely to reuse a UI operation. App owns native lifecycle and immediate cleanup.
