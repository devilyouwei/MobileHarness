# ADR0167 — Agent-routed speech model binding

Accepted: 2026-10-07. Implemented; design updated before code.

ResourceManagement receives typed configureSpeech(recognition, synthesis) through InputGateway and selects System.ModelResources.configureSpeech through OutputGateway. No model-callable grant is added. One live configuration call rejects overlap; downloads/cancel/removal retain independent admission. A standard function validates two boolean strings and invokes a narrow native capability.

App composition injects lifecycle barriers and ModelKitDefaults configuration into its existing native adapter. The adapter suppresses unchanged native binding tuples and only updates its cache after successful binding. It does not choose preferences or access settings persistence. Shutdown joins the owned call as for other resource commands.

Settings retains source persistence and installation prerequisites in this stage. Persistence precedes application; a committed preference is not rolled back on dispatch/application failure. Invalidate cached preference after commit and propagate failure; a later explicit restore retries the durable preference. No silent fallback or automatic retry.

❌ Source/preference decision and persistence ownership, provider selection and resource state presentation remain staged work.

## Validation

✅ scripts/check.sh final run passes:530 IntegrationTests and37 AppWorkflowTests. New regressions cover typed preference delivery, strict boolean validation before effects, overlap rejection and failure followed by a successful next call. Workflow coverage verifies durable commit, cache invalidation and explicit retry. Device-target build and7 packaged configs pass;196 Mermaid diagrams parse.

The first full run had two existing BLE test failures (disconnect/timeout). Both passed isolated reruns and the final full run; no Bluetooth implementation was changed in this stage.

❌ scripts/build-ios.sh remains blocked by the external CoreAIShared simulator dependency missing CoreAI. Physical model switching and resource acceptance remain unverified.
