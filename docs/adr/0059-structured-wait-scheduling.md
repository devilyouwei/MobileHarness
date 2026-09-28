# ADR 0059 — Structured wait groups for Action scheduling

Date: 2026-09-28. Status: accepted and implemented; device acceptance pending.

## Context

A Channel is a FIFO lane, not a dependency group. The former interpreter erased scope boundaries and produced only ActionCalls; assigning all work to main serialized speech and captions and could not express a parallel group followed by a continuation. Shared cross-task Channel queues would also allow a dormant dependency to obstruct unrelated work. A new prompt alone cannot supply these missing runtime semantics.

## Decision

Add paired, attribute-free `<wait>...</wait>` with entry/exit synchronization. A wait joins earlier work in its parent, runs its contents by normal Channel rules, then joins all children before its parent continues. Support nested waits using a task-local tree, never a global idle check. A unified lexical stack rejects crossed Channel/wait closure and limits combined depth to eight. Preserve typed begin/end directives through generation, Assistant substitution, output validation and scheduler admission; no model-created group IDs or control strings.

The scheduler actor owns per-task groups and phase-local FIFO lanes. Only active lane heads enter admission-sequence resource arbitration; dormant groups hold no module lock. Device exclusion remains process-wide. Channel names no longer impose cross-task FIFO. Remove implicit main from the registry and Assistant declaration; explicitly registered main remains an ordinary name. Natural text mappings retain their existing independent lanes, without introducing an ActionStep batch abstraction. Native Tools and synthesis prefetch stay outside the Action tree.

JSON remains v4; wait becomes a reserved alias. App, prompt, parser, registry resources and scheduler ship together. Existing Channel-only programs keep task-local ordering, but no longer receive cross-task same-name FIFO. No silent compatibility mode translates old main usage into waits.

## Bounds and failure

Each task admits 120 Actions and 32 waits; root plus child groups require at most 65 phases. Default global limits remain 64 tracked tasks, 16 live Channel names and 32 unfinished Actions per name, including dormant work. Assistant buffers 256 output events. Capacity rejection is explicit. First handler error cancels the task tree and fences late producer admission until finish/cancel releases it. Cancel joins cooperative cleanup; completed effects are not rolled back. finish rejects unclosed waits. Waiting adds no timeout and does not suspend existing model/cache expiration.

## Consequences and evidence

✅ The model-facing distinction is small: Channel selects a lane, wait supplies parent-local dependencies, and module exclusion prevents device conflicts. Tree state permits streaming execution before XML group closure while keeping continuations gated until closure and full completion. Raw diagnostics retain and display typed boundaries without running them.

✅ Deterministic tests cover parser splits, invalid syntax, nested entry/exit dependencies, independent-task progress, capacity, error and cancellation cleanup. Check/build results are recorded in the roadmap/validation report after the implementation checks run.

❌ Arbitrary dependency graphs, Tool grouping, global barriers, priority, preemption, rollback and hardware takeover are not added. Handlers must cooperate with cancellation. Long waits may expire prefetched audio. Model syntax reliability and physical-device behavior require separate acceptance.

This supersedes the scheduling/shared-lane portion of ADR 0018. Current exact contracts live in AgentCore/Generation and Gateway/Output/Scheduling READMEs; original design sources and earlier ADR narratives remain preserved.
