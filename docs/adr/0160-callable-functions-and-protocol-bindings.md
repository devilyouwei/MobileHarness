# ADR0160 — Callable functions and protocol bindings

Accepted: 2026-10-06. Refines ADR0157/0159. The active design was changed before implementation.

ActionFunction is the pure implementation descriptor; @Action has no protocol, native scheduling or feedback arguments. Runtime ActionBinding selects protocols, native execution and feedback while wrapping one immutable function. Registries store bindings; common execution consumes the function. Capability catalogs validate intrinsic metadata before host binding.

App/Composition/Behaviors owns grouped built-in profiles and rejects unknown domain/module groups; Agent JSON/code remains the authority for model exposure and permission. Native result/request formats and ToolModule stay within Runtime/Gateway. Business modules use neutral producer failures and PoseOverlay; partial catalogs describe capabilities only.

✅ Implemented: pure ActionFunction factories/catalogs, host ActionBinding profiles, shared function execution and neutral producer failures/payloads. Boundaries preserve one implementation, resource/deadline constraints and independently authorized calls. Five focused regressions,506 IntegrationTests,37 workflow tests and unsigned iOS device build pass; simulator validation is blocked by the missing CoreAI module. See Validation-History.md for the initial recovery timeout and passing reruns.

❌ Remaining Signal/feature migration, model continuation and physical/model acceptance are separate work.
