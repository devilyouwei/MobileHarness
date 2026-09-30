# ADR 0084 — LLM output buffering

Status: accepted, 2026-09-30.

## Context

A conversation performing successive expressions failed with bufferOverflow. Cloud and local LLM adapters both imposed a 128-event pending-output limit. Fragment count is neither token count nor reply length; consumer work can lag behind a finite producer. The screenshot alone does not prove the throwing site. The user explicitly requested removing this queue limit rather than increasing it or pausing generation.

## Decision

StreamLimits accepts an optional event capacity: positive values preserve the existing bounded stream, nil selects AsyncThrowingStream.unbounded. Only cloud/local LLM adapters opt into nil. Default capacity remains 64; audio and other queues are unchanged. This is an explicit exception to the repository's general bounded-queue rule.

No pending LLM fragment is rejected because of backlog size. Normal completion drains accepted events in order, including the finish reason. Error/cancellation still terminates consumption and the producer; single-consumer and per-event byte validation remain. No extra workers, duplicate sources or dependencies are introduced.

Cloud retains its existing 8 MiB cumulative SSE response limit, per-event limit, request timeout and provider generation budget. Local Qwen retains its 4096-token prompt-plus-output context, EOS handling and per-event byte limit. A finish marker is not the only termination mechanism: malformed/truncated responses, transport failures and cancellation remain explicit errors.

## Consequences and validation

Pending reply memory grows with the number and size of produced events, including event object overhead. There is no fixed queue-memory ceiling. Downstream history/parser, Action and speech limits still apply; this change does not guarantee every long multi-action plan succeeds.

✅ Regression coverage queues 20,001 Core events before consumption and 1,024 cloud text events through an offline URLProtocol before consumption, checking exact order and completion. Bounded overflow, size rejection and cancellation remain covered.

❌ Real-provider/iPhone expression replay and memory/latency acceptance remain separate from automated checks.
