# ADR0166 — Agent-routed model resource commands

Accepted: 2026-10-07. Implemented; owning designs updated before code.

Route download admission, explicit cancel and removal through typed model.resource.intent/1 to a root-session deterministic ResourceManagement Agent. Fixed permissions select protocol-neutral System.ModelResources functions; returning results cross InputGateway and select terminal output controls. App adapts ModelKit capability inputs and maintenance cleanup. Download success is admission only; native transfer/install state stays ModelKit-owned. Existing source persistence, preferences, status reads and interaction locks remain staged; no Assistant model mutation permission is added.

Use existing directories: root Agents owns the new actor/JSON and role documentation; System owns callable module functions; App Settings owns bounded transport; App Adapters owns SDK adaptation. No new directory, target or model instance. AppSettingsWorkflow adds narrow AgentCore/Agents/Gateway dependencies without importing concrete callable/model services.

One live resource Agent,32 pending requests,64 buffered outputs and32 retained workers. Reject overflow/duplicates, fence feedback by host session/call identity and join the matching worker before completion. Admission survives page cancellation; explicit resource cancellation is another accepted command. Shutdown rejects new work, joins execution and closes pending waiters. Execution/delivery failure remains invocation-local, with no retry or replay.

Validation is recorded below. Source/preferences, registered resource-state presentation, long-task Signals, provider selection and model-callable resource exposure remain separate work.

Host-only typed retire(request UUID) enters as an external runtime-source intent to release invocation bookkeeping after dispatch/feedback failure. It cannot cancel a transfer and grants no model-callable permission. Shutdown shares a cleanup task; external shutdown also joins the output reader without self-joining from stream termination.

## Validation

✅ scripts/check.sh passes, including525 IntegrationTests and36 AppWorkflowTests. Dedicated resource cases verify gateway execution, failure recovery,32-request capacity/duplicates, page cancellation, independent explicit cancel and joined shutdown. Device-target build succeeds and all7 packaged Agent configs match source;195 Mermaid diagrams parse.

❌ scripts/build-ios.sh remains blocked in the external CoreAIShared simulator dependency because CoreAI is unavailable. Physical download/cancel/delete and background restoration acceptance remain pending; no real model transfer was performed by fixtures.
