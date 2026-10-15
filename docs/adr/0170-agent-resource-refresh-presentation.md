# ADR0170 — Agent-selected resource refresh presentation

Accepted: 2026-10-07. Design updated before code.

A generation-bearing refreshPresentation intent enters ResourceManagement through InputGateway. The Agent selects UI.ResourcePresentation.showResources. This protocol-neutral Action reads the same neutral inventory capability and shared inventory validation as System.ModelResources.snapshotResources, then invokes an injected presentation endpoint. Only OutputGateway dispatch may reach the production endpoint. The UI callable returns the canonical inventory after accepted state commitment; the host retains existing32-request/64-output bounds and at most two sequential calls per request. No large inventory is embedded into call arguments and no second native query is required.

On callable failure the Agent selects showResourceFailure with the same generation and a bounded2048-byte message, waits for returning feedback, then terminates the original request as failed. Retain the primary failure and append any presentation failure; never recurse or terminate unrelated calls. Transport/admission and preference-reconciliation failures still use the existing workflow error surface when no registered presentation was accepted; these are explicit remaining migration work, not a fully Agent-driven error path.

App injects a root-session presentation adapter and maps neutral inventory into existing UI values/text. UI stores a passive refresh revision: starting a refresh or admitting a mutation invalidates older revisions. The adapter rejects stale/session-mismatched updates before assignment. Snapshot acceptance commits items/groups only; preference reconciliation follows separately, and later failures do not roll back a displayed snapshot. Command locks, draft changes and non-refresh errors retain their current ownership in this stage.

Both UI functions use standard FunctionInput and pure injected endpoints. Host registration chooses returning/direct Tool calls; the functions have no Tool/Agent/Gateway/UI dependency. Assistant model permissions stay unchanged. Once separately authorized model intent routing is added, manual and model-triggered operations reuse these functions; this stage does not claim conversational resource control is complete.

✅ Implemented as designed. No new directory, target or dependency.

✅ Seven resource-presentation regression tests pass with real Agent/Gateway/function composition and controlled endpoints: single read/accepted snapshot, large returning inventory, primary/secondary failure, unavailable error presentation, invalid input and UTF-8 combining-character bounds. All38 workflow tests pass, including stale revision rejection and avoiding duplicate projection of already-presented errors.

✅ Source/target boundaries, formatting, Python checks, unsigned generic iOS device build and7 packaged Agent configurations pass. All197 current MobileHarness Mermaid diagrams parse;298 local Markdown files have no missing link paths; diff whitespace passes.

❌ Final check.sh does not pass: its547-test integration run has one unmodified bluetoothPassiveRefreshNeverBlocksManualResetOrIssuesQuery failure (readiness expectation followed by timeout). That test passes independently. Earlier full runs failed different BLE timing tests, which passed in a later545-test full run before the two final failure refinements. This is recorded as outstanding full-suite stability, not proof of a baseline cause or a passing final suite. No Bluetooth production/test source was changed in this stage.

❌ Required simulator build fails in external CoreAIShared because CoreAI cannot be resolved. No phone installation, native UI, live-model or physical acceptance was performed. Detailed evidence is in [validation history](../validation/Validation-History.md).
