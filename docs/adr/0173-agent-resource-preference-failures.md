# ADR0173 — Agent-selected resource preference failure presentation

Accepted: 2026-10-07. Design updated before code.

Preference producers expose protocol-neutral failure codes: resource.source.invalid, resource.selection.recognition and resource.selection.synthesis. The existing execution adapters preserve these codes in correlated feedback; runtime does not interpret them. ResourceManagement classifies preference-function failures by exact code, not error-text matching. Binding failure is always execution failure, even when its underlying code resembles a preference validation code.

The Agent selects UI.ResourcePresentation.showResourcePreferenceFailure(reason,message). Reasons are invalidSource, recognitionRequired, synthesisRequired or execution; message is nonblank and bounded to 2048 UTF-8 bytes. The canonical function validates arguments and awaits a required neutral endpoint. App validates root session and localizes the selected reason into the existing installation notice or ordinary error state. Missing-model notices clear ordinary error; progress recovery does not erase ordinary preference errors. Functions have no UI/Agent/call-protocol dependency.

Preference read/save plus binding plus failure presentation needs at most three returning calls. ResourceIntentRuntime grants that limit only to restoreSource/saveSource requests; commands, observations, standalone configureSpeech and inventory retain two. Requests/output slots remain 32/64, one joined current worker per request. The Agent retains preference/configuration exclusion through the failure-presentation attempt. That attempt always finishes the failed request; failure does not recursively present or repeat persistence/binding. Stop/retirement/overflow clear the shared terminal-presentation identity set.

Durable writes survive later binding/presentation failure. The interaction coordinator restores only last-confirmed visible flags and suppresses local projection after acknowledged registered presentation; no effectful rollback or implicit binding retry. Facade cache invalidates on failure. Host/admission/malformed-feedback or unavailable endpoint failures retain explicit local fallback and primary/secondary causes. Legacy substring interpretation remains solely in that fallback, documented as migration debt.

No directory, target, dependency, model-callable grant or native resource algorithm changes.

✅ Implemented in preference producers, ResourceManagement, canonical presentation module and App endpoint/transport. Regression fixtures verify exact codes, binding-stage distinction, three-call completion, gate lifetime, durable state, failed/missing presentation and visible rollback. Final validation is recorded in Validation-History.md.

❌ Host/admission/unavailable-presentation fallback migration, provider settings, shared resource context and native UI/device acceptance remain outstanding.
