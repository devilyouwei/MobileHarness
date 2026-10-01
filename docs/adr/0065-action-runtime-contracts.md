# ADR 0065 — Action implementation contracts and execution diagnostics

Status: Accepted; stage 1 implemented.

## Context

The Actions authoring standard distinguishes finite operations, state setting and activity-control commands. Existing handlers could express their different completion points, but registration contained only closures, invocation duplicated call data, argument conversion varied, and failures had no bounded per-execution history. Scheduling, lookup and presentation errors shared one enum. Startup did not verify all assembled Action grants against implementations.

## Decision

Keep the existing awaited Void handler and task-local Channel/wait algorithm. Add immutable ActionDefinition metadata (path, kind, completion description and handler), a throwing array-based registry that rejects duplicate/invalid entries, and explicit coverage checks against each Agent's assembled model/internal capability registry. App performs coverage checks before starting producers without duplicating Agent grants. JSON v5 is unchanged.

Construct ActionInvocation from one Action envelope. Remove the independent call argument and scheduler path argument. Every admitted job gets a fresh execution UUID which is returned as a receipt and propagated to its handler and diagnostic records. Reusing an invocation means a new execution, not idempotent retry. Constructors guarantee consistency, not authorization; Gateway and endpoint checks remain required.

Introduce ActionArguments for bounded typed decoding and unknown-key rejection. Adopt it in existing UI Actions while retaining domain errors and semantic parameter limits. Move Channel/input/wait errors into Gateway.ActionSchedulingError and presentation errors into UIActions.PresentationError. Original dependency/cancellation failures still propagate.

The scheduler owns a circular diagnostic history (default 256, maximum 4096 records), overwritten oldest-first with a visible eviction count. Records contain only identity, kind, phase, effect status and monotonic time. They contain no payloads or error descriptions. Queued cancellation is notStarted; after entering execution, failure/cancellation has unknown effects. Success establishes only the registered completion contract. Running terminal events are recorded after handler cleanup, not when cancellation is requested. Eviction never changes Action execution.

## Consequences and compatibility

- ✅ Runtime definitions are limited to 256; path components to 64 UTF-8 bytes; completion descriptions to 512 bytes. These bounds do not alter Agent capability limits.
- ✅ Startup can reject missing implementations before real model/device use. Coverage is structural; it cannot verify the truth of completion descriptions.
- ✅ Registry construction, invocation and scheduling APIs changed; production assembly and root tests migrated together. Source callers must use definitions, a single envelope and enqueue(invocation:).
- ✅ UI locally rejects unknown keys even outside Gateway. Existing valid values, Action paths, callback signatures, turn/session behavior and playback completion remain unchanged.
- ✅ Snapshot retrieval is bounded and pull-based; no diagnostic queue, subscriber worker, persistence or automatic feedback channel exists.
- ✅ AgentCore stays independent and no new dependency is introduced. Actions contains definitions/readers/diagnostic values; Gateway owns scheduling transitions; App owns assembly.
- ❌ Metadata does not create activity owners, resource leases, deadlines, rollback, preemption or retry deduplication. Those require implementation with the first real continuous activity.
- ❌ Namespace/file/signature unification for existing business Actions remains a separate migration. Hardware, animation and sustained-device acceptance remain outside automated checks.

## Validation

Contract tests use explicit acknowledgments for finite/state completion, unknown effects after cancellation, failure propagation, unique admission IDs and diagnostic eviction. Existing integration coverage continues to exercise nested waits, bounds, module exclusion, cancellation cleanup and voice/UI flows. Repository checks passed, including 151 IntegrationTests (9 new contract tests), and all four unsigned simulator builds passed. README examples passed Swift 6 type checking and formatting. Opt-in real-model evaluations were skipped; these results do not establish physical-device behavior.
