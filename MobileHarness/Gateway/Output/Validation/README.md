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
