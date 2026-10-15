# ADR0169 — Agent-routed resource inventory

Accepted: 2026-10-07. Design updated before code.

Resource status refresh becomes typed refreshResources input to ResourceManagement. A fixed internal snapshotResources call crosses OutputGateway; native facts enter a neutral Actions capability and returning results cross InputGateway before terminal completion. The host returns canonical JSON to a view adapter only after successful terminal dispatch. No Assistant/model-callable permission is added.

Actions owns the inventory schema, progress clamping and installed prerequisites shared with source transactions. Maximum64 items/65536 JSON bytes; reject oversized fields, negative counters and duplicate IDs without returning partial success. App maps SDK phases/metadata into neutral facts and translates successful results to passive UI values, retaining localized status/failure messages. UI/Settings adds a view snapshot value only, with no dependency/effects.

The Settings facade returns a view snapshot with items and precomputed installed groups. Interaction preserves its generation fence, command locks and preference failure guard; it no longer decides installed eligibility. Transport uses the existing32-request/64-output bounds, requires returning feedback and retains invocation-local failure plus joined shutdown. Preferences remain maximum2048 bytes; inventory results have their own65536-byte bound.

Registered UI presentation/failure functions, observation-driven progress, provider routing and physical acceptance remain outstanding. This read migration does not claim the entire presentation path is Agent-driven. No new directory, target or dependency.

The65536-byte inventory bound matches InputGateway returning ToolResult value admission. CommunicationContracts maximumBytes governs registered observation content; its default is not a separate bound on ToolResult values.

✅ Validation: check.sh passes all540 integration tests and36 workflow tests, independent targets, source boundaries, formatting and metadata checks. Inventory fixtures verify progress/error preservation, shared prerequisites, duplicate/negative/item/byte rejection, a valid result above48 KiB across both Gateways and successful retry after overflow.

✅ Unsigned generic iOS device build passes; all7 packaged Agent configs match; all194 current MobileHarness Mermaid diagrams parse; local Markdown links and diff whitespace pass. ❌ Required simulator build stops in external CoreAIShared because CoreAI cannot be resolved. No phone installation, real model/native transfer or physical acceptance was performed. See [validation history](../validation/Validation-History.md).
