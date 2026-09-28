# Validation — Resolved Output Authorization

Purpose: reject undeclared output before execution. Validation checks the source Agent's declared kinds, resolved paths, string parameters and available channels.

- ✅ OutputGateway looks up the descriptor using the trusted envelope source before validation.
- ✅ OutputValidator checks OutputKind.actionCall/toolCall permissions and validates resolved ActionCall/ToolCall against the capability registry.
- ✅ Required/optional parameter names and effective channel allowlists are enforced.
- ❌ Full JSON Schema and unified resource/device permissions. Platform adapters enforce their own permissions; capability allowlists do not grant hardware access.

Update this README when changing the validation contract or implementation status.


✅ Typed scheduling directives require OutputKind.scheduling in the Agent descriptor. Scheduler admission validates balanced boundaries, task/session identity and group bounds. OutputGateway cancels the owning task when output validation fails; raw wait XML is never accepted here. ❌ Tools are not members of Action wait groups.
