# ADR0172 — Agent-selected resource command failure presentation

Accepted: 2026-10-07. Design updated before code.

Download, cancellation and removal retain their native algorithms and admission/completion boundaries. On correlated failed feedback, ResourceManagement selects UI.ResourcePresentation.showResourceOperationFailure(message), awaits its result and finishes the original request as failed. Presentation failure never retries the device command or recursively presents another error. Primary execution and secondary presentation/dispatch causes remain in the request-local error chain. Pending requests/output slots remain 32/64; command plus presentation fits the existing two-call limit.

The new canonical function accepts only a nonblank message of at most 2048 UTF-8 bytes, awaits a required injected endpoint and returns its declared acknowledgment. It has no Agent, UI or call-protocol dependency. Gateway registration retains the existing returning direct ToolCall profile for this module; there is no model-callable grant.

App's endpoint validates the root session before assigning passive operation error state. Operation errors are independent of refresh generations: a completed command may fail after another snapshot, and later progress must not clear that error. This preserves completion-order presentation. The interaction coordinator recognizes the accepted-presentation failure marker and avoids duplicate local projection while preserving admission/cancellation cleanup. Host rejection, missing feedback/transport and unavailable presentation continue using the existing explicit local fallback and retain the original cause; they do not pretend presentation succeeded. Error descriptions expose the retained chain.

Preference/installed-prerequisite notices remain staged because they have distinct typed notice/rollback semantics and two-call preference binding. No new directory, target, dependency, UI queue, native algorithm or runtime isolation change.

✅ Implemented in the existing resource Agent, canonical presentation module and root adapter/transport. New regressions cover all three command failures, no replay, subsequent-request recovery, failed/missing presentation and strict argument validation; interaction retains accepted errors and releases locks. Final validation is recorded in Validation-History.md.

❌ Preference notices, unavailable-Gateway host presentation and native UI/device acceptance remain outstanding.
