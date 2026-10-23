# 0218 - Direct foundational container inputs

Status: accepted. Scope: external input routing and business-module compilation.

## Decision

Agents directly consume typed UI requests, native audio/video and runtime facts through injected foundational capabilities. Remove AgentBindings/ActionBindings compilation targets and external Signal adaptation, host dynamic subscriptions and source lists. Actual business execution services and role completion/session owners stay inside Actions and Agents respectively.

Signals carry Agent communication and execution feedback. ProcessingContext preserves local request/session/generation/turn/causality; local provenance is rejected by Gateway ingress. User/model effects still execute through bound Gateway consumers and Actions with authorization, resources, cancellation and actual completion.

Foundation modules and AgentCore remain independent. No replacement universal broker, new module, persistence format or third-party dependency is introduced. Typed UI receipts are bounded to 64 outstanding items per participating subcontainer, and native latest/ordered overflow contracts remain explicit.

## Reason

Direct inputs avoid redundant transport envelopes, serialization/validation and routing. Native PCM retains immutable Float storage. Actual performance magnitude requires matched device measurements; no numerical improvement is assumed.

## Supersession and limits

This decision replaces the external-input portions of the earlier unified Signal and direct admission decisions; Agent-to-Agent and execution feedback authority remain in force. Historical ADRs and original Technical_Design.docx remain evidence of their original designs. Real model, native UI and physical/performance acceptance are recorded separately in the migration requirement and validation record.

## UI ownership

Inject actual UI subcontainers into the owning Agent. UI inputs are consumed in the Agent lifecycle and handled by role methods; application composition does not subscribe or dispatch requests to execution sessions. Bind the identity-scoped output consumer before Agent startup. Fixed UI outputs reuse Gateway/Actions authorization and real feedback, without an input transport. Home listening is a separate control-only source so the perception role owns consent directly.

## Native input ownership

The perception role owns the read-only native input capability and consumption task. Capture execution owners start/stop hardware and join role input shutdown, without obtaining or forwarding frame streams. Native PCM has one ordered 64-packet source, with one consumer and explicit overflow; the role applies admission, DSP and conversion before pulling the next packet. Camera retains native latest replacement and the role's single inference/latest pending frame. Role-local processing files are implementation, not an input broker.

## Execution ownership

Native capture/playback and voice presentation execute inside Actions. Agents retain role registration, model decisions, direct read-only inputs and output pumps. Inject already established role lifecycle contracts without exposing AgentManager, role factories or Gateway implementations to Actions. Microphone telemetry uses a generation-fenced Actions presentation service; it never becomes an external input Signal. Emergency shutdown joins physical cleanup independently of model decisions.

## Remaining entry-point convergence

UI gestures and diagnostics enter their responsible role directly. Full history queries use an internal protected function with a per-request typed attachment/result slot, rather than a global staging table or full-data JSON round trip. Execution attachments cannot originate from a model round, carry a delegated scope or mix with native media. The handler separately validates actual source, session and request identity.

Stateful interaction feedback and diagnostic projection belong to Actions; local forms/focus remain UI-owned and observation/policy remain Agent-owned. New internal functions do not expand model Skills. Missing optional execution capabilities return explicit failures rather than missing handlers or fabricated success. Simulator dependency isolation is an explicit build choice, not a replacement model.
