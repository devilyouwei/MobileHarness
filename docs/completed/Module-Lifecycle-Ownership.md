# Module lifecycle ownership

App owns root configuration and ordered scene transitions. Remove camera/device scene invalidation, suspension and shutdown from AgentContainer and its host protocols. ActionsContainer owns asynchronous native suspension and resume through configured callbacks, preserving cancellation joins, revision fencing and failure propagation. App forwards home visibility separately to Actions; page visibility must not reopen scene admission. Agents retains perception/role cleanup and model-maintenance business requests.

Split AgentGatewayAssembly into cognitive preparation and completion accepting public Gateway ports. App calls GatewayContainer.configureExecution directly. Keep policy/result conversion within Agents; no Agent helper receives the Gateway root. Update the observation integration fixture accordingly.

Affected: ActionsContainer/ActionsBusinessAssembly; AgentContainer/AgentBusinessPorts/AgentGatewayBindings; App composition/presentation adapters and lifecycle wiring; owning README files and overall design. Add regression tests for Actions native pause/resume joins and failure. Run check.sh and build-ios.sh; record limits separately from physical acceptance.

## Completion — 2026-10-31

Implemented Actions-owned native scene joins, separate App page visibility, narrowed Agent host ports and direct App Gateway configuration. Added native pause/resume and failed-pause admission regression tests; updated the observation integration fixture and architecture boundary checks. Validation: [Module lifecycle ownership](../validation/Module-Lifecycle-Ownership.md).
