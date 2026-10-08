# ADR0181 — Photographer camera control ownership

Accepted: 2026-10-08. Design precedes code.

## Decision

Photographer owns camera open/close/front-rear switch/retry decisions. Retain existing Camera.Capture functions and native permission/capture/safety/cleanup. Remove camera from ResourceManagement. A root-owned Photographer outlives preview and binds one explicit vision scope for existing tracking, avoiding self-cancellation when closing capture.

Manual operations enter InputGateway as photography.camera/1. Existing Assistant camera Tools use a host adapter to delegate an authorized Agent Signal through OutputGateway before Photographer invokes the same canonical function. The outer and inner camera Tools are direct with no camera resource claim, so there is no nested scheduler/resource lock. Native capture owns its ordinary single worker/lease. The original Tool response includes the full nested failure report.

Gateway binds only OutputEnvelope during a direct Tool invocation; delegation checks exact execution context and existing send permission/incarnation/causality/hops. Business functions remain protocol-neutral. No original media payload is retained.

## Ownership and bounds

One Photographer registration, root camera UUID, at most one attached vision UUID and one admitted camera command. One stream consumer; camera worker is independent of one tracking worker plus8 queued tracking outputs. The Agent stream remains8. Excess tracking calls report rejection, while explicit session retirement cancels accepted old tracking work and joins cleanup. Camera cancellation joins its function before root cancellation Signal/ack; request admission stays closed until retirement. Shutdown cancels/joins all owned tasks before removal.

Actor admission checks root user camera commands, bound Assistant commands, attached vision poses and correlated runtime ToolResults. Manager registration is unscoped only for this multi-domain role; no global validation is loosened. Session replacement resets freshness/ordering/filter state. Stale feedback/poses cannot affect replacements.

✅ Implementation complete. Full repository checks passed with596 integration tests and51 workflow tests, including camera dispatch/delegation/error/cancellation/scope regressions. All210 source Mermaid diagrams parse. Unsigned generic iOS device build and seven-config byte-for-byte packaging verification passed; Simulator remains blocked by external CoreAI. No native UI, real-model or physical-device acceptance was performed. No new directories or targets; no still/video recording features, motion algorithm changes, physical acceptance or generic request/reply protocol are implied.

Invocation context also captures the original ExecutionOwner incarnation, rejecting stopped/replaced sources rather than binding their replacement. Root output pumps are detached owned tasks so a long-lived service cannot inherit a caller’s invocation authority.
