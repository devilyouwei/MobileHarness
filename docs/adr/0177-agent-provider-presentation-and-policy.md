# ADR0177 — Provider presentation and policy completion

Accepted: 2026-10-08. Design precedes implementation.

Move chat-family filtering from ModelKit to Actions, preserving existing app discovery behavior. Extract all SettingsState asynchronous orchestration to existing App/Workflows/Settings/SettingsFormController.swift. UI state contains editable values/status and typed control interfaces only.

Presentation-enabled opaque provider intents select business then registered UI result commitment. Root call bound is two, headless one. Private results and root presentation registrations retain session, request and form revision, with capacity32 and explicit discard. Failed business calls select one error presentation, preserve primary failure, and never replay. Presentation failure does not recurse. No credentials or provider URLs cross calls/Signals. Page departure cancels only query presentation, not committed save/rollback.

No new directory, target or dependency. Physical/provider acceptance is separate from compile/fixture validation. Broader completion tracks include bounded model continuation, resource grants/context, typed lifecycle/device/navigation entries and real-device acceptance.

✅ Implemented, including removal of UI installed-model checks before save; transaction preparation validates prerequisites. Automated/native build evidence is recorded in [validation history](../validation/Validation-History.md).
