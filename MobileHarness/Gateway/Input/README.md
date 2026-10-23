# InputGateway - Agent communication and execution feedback

## Responsibility and interfaces

InputGateway validates Agent/runtime provenance, schema, source identity, session/incarnation, causality, deadline and capacity. Only OutputGateway's bound internal send/publication paths and execution feedback enter admission. There are no public external send/publish, dynamic host subscriptions, native codecs or container fault channels.

Local UI, device frames, OS facts and container errors are consumed directly by their owning Agents. `local` provenance is rejected by transport validation; no external-input origin exists. Static Agent subscriptions are declared in role configuration and must name a real registered publisher.

## Data flow and ownership

OutputGateway supplies bound message sources and resolved destinations; execution delivers owner-fenced Tool/Action/activity/round feedback. Recipients own their inboxes, ordering, fusion and business meaning. The transport does not infer, capture, render or maintain an independent waiting queue.

Agent publication is bounded one-way fan-out. It does not acknowledge business consumption; no recipients and rejected branches remain observable diagnostics. Directed messages return admission evidence, while actual task completion uses its explicit contract. Shutdown cancels and joins in-flight publications, closes observers and retires no side effect by replay.

## Bounds and failure contracts

Admission/publication retains 128 operations, 256 branches, 16 targets and 8 MiB observation retention. Ordinary schema payloads and hop/deadline/session checks remain enforced. Receivers admit or reject promptly; full buffers reject explicitly rather than awaiting model progress.

Signal and task diagnostics each retain 256 rows with counted eviction and share eight newest-one observers. Task history/observations remain isolated from ordinary traffic. Media and credentials are excluded from summaries. Feedback preserves original processing causality, owner/session/incarnation and genuine execution completion; transport retry cannot re-execute effects.

## Outstanding work

Remote transport and durable feedback delivery remain unimplemented. See [Gateway](../README.md) and [overall flow](../../README.md).
