# ADR0176 — Agent-routed provider configuration transactions

Accepted: 2026-10-07. Design updated before code.

Provider restore/save uses opaque provider.settings/1 intents through ResourceManagement and one returning registered System.Provider function. Actions owns schema, document/credential-reference persistence, restore/cache, preparation-before-effects and complete save/apply/rollback transaction. App injects raw native credentials, SDK preparation/apply and lifecycle barriers; its settings facade only coordinates form requests. No secrets cross Signal/call/feedback boundaries. Private request/results have32 total slots,10-second unclaimed deadlines and session/operation/one-use guards; root transport retains32 requests/64 outputs.

Preserve v1 schema, Keychain service/accessibility, read-back before legacy deletion and post-commit old-key cleanup. Validate/prepare before beginChange or persistence; persist before apply. Failed apply rolls persistence back before endChange and leaves confirmed cache unchanged. Cancellation cleanup uses independently owned joined rollback. Report both primary/rollback safe codes without secret text. Restore applies saved configuration before confirming results. Provider transactions share Agent configuration exclusion with source preferences/speech binding; discovery remains independent.

Replace App business implementation, do not retain old/new transaction copies. Provider UI presentation, native Keychain/provider acceptance, SDK model-family policy migration and model-callable grants remain later work. No new directories/targets/dependencies.

✅ Implemented: provider schema/store/service/private staging now belong to Actions, with one cohesive ProviderModule catalog. App provides only native credential/SDK/lifecycle adaptation and bounded form coordination. ProviderIntentFailure replaces the discovery-only name; no alias/duplicate transaction remains. Regression and build evidence is recorded in Validation-History.md.
