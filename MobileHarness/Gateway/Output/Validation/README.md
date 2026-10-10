# Validation — Resolved Output Authorization

Purpose: reject undeclared output before execution. Validation checks the source Agent's declared kinds, resolved paths, string parameters and available channels.

- ✅ OutputGateway looks up the descriptor using the trusted envelope source before validation.
- ✅ OutputValidator checks OutputKind.actionCall/toolCall permissions and validates resolved ActionCall/ToolCall against the capability registry.
- ✅ Required/optional parameter names and effective channel allowlists are enforced. rejectedCall requires its corresponding actionCall/toolCall output kind but has no executable path or parameters; it never grants invocation permission.
- ❌ Full JSON Schema and unified resource/device permissions. Platform adapters enforce their own permissions; capability allowlists do not grant hardware access.

Update this README when changing the validation contract or implementation status.


✅ Typed scheduling directives require OutputKind.scheduling in the Agent descriptor. Scheduler admission validates balanced boundaries, task/session identity and group bounds. OutputGateway cancels the owning task when output validation fails; raw wait XML is never accepted here. ❌ Tools are not members of Action wait groups.

✅ ADR0098: Gateway imports AgentCore, FunctionContracts, ExecutionRuntime and CallRuntime only. Concrete Actions/Tools, platform and model implementations are outside this compilation boundary. Existing routing, queues, resource fences and cancellation order are unchanged.

✅ ADR0156: canonical execution addresses use domain/module/function; Agent v6 bindings resolve native names separately. Existing serialization/resource and output permissions are preserved.


✅ ADR0157: canonical executable definitions and shared outcomes replace duplicate protocol metadata; consumers import Actions/FunctionContracts. Protocol request views remain adapters, and production permission/resource boundaries are preserved.

❌ Physical acceptance and additional business capability exposure are not established by this migration.

✅ ADR0161: standard callable inputs use FunctionInput/FunctionContracts; common execution and call protocols belong to independent Gateway targets. This directory retains its existing ownership, resource/permission and lifecycle boundaries. ❌ Remaining feature Signal/continuation and physical acceptance are separate work.

## Agent composition — ADR0187

✅ Agent 自有预处理、版本化结构化 Context 和 Builder 已接入；共享机制在现有 Agents/Support/Core 与 Agents 目录中。业务职责保持当前分界。函数结果按运行时捕获的执行所有者定向返回，通信投递回执只表示接纳；模型续轮不订阅自身广播。

✅ 上下文采用有界原子提交，重启将未完成工作标为中断，不重放设备动作。普通输入、反馈和控制分别接纳；所有容量或持久化失败显式返回。音视频和原生会话保持有界临时状态。

✅ 第二阶段已实现独立摄影 LLM、正式任务委派及任务定向后续输入。❌ 真实模型、原生 UI、真机语音验收仍待完成。

输出运输使用 GatewayOutputConsumer 在读取之前绑定真实 Agent actor/incarnation；旧实例迟到输出不能借用新注册权限。OutputGateway 验证 JSON 通信声明与任务 grant，函数/通信消费者独立；App 通信分支最多16个待处理、4个并行投递。请求回执、子任务报告、函数结果分别关联；TaskResult 在执行清理屏障后投递，目标停止合成明确终态并记录无法投递的失败。

输入 Gateway 只处理来源/协议/容量/权限；外部输入禁止伪造 taskScope、运行时反馈或 incarnation。任务输入接纳仍由目标 Agent 的业务 Schema/策略决定，不在 Gateway 拼接聊天内容。

设计与阶段边界见 [ADR0187](../../../../docs/adr/0187-agent-composition-and-react.md)；验证见 [Validation-History](../../../../docs/Validation-History.md)。
