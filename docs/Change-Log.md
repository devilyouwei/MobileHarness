# Documentation and architecture change history

Purpose: retain dated documentation corrections and architecture changes without turning source-directory READMEs into change logs. For decisions that alter runtime contracts, follow the linked ADR; current behavior remains in the owning module README.

## 2026-09-27 — Module documentation audit

- AgentCore: removed the InternalSignalBus description; Communication now documents contracts and policy while Agents own pending inboxes.
- Agents: replaced generic directory sketches with current roles and removed stale expression and migration examples.
- App: consolidated repeated presentation updates and corrected skeleton execution from Action to completion-only Tool.
- Gateway: removed model-processing ownership and distinguished returning Tools from completion-only Tools.
- ActionRuntime and ToolRuntime: clarified execution ownership versus Gateway admission/scheduling, and clarified that skeleton coalescing belongs to VisionPerception.
- Actions: removed obsolete emoji/expression and Photographer Action claims; skeleton presentation belongs to Tools/UI.
- ModelKit: removed old Gateway ASR/VAD ownership, YOLOv8 default and Photographer inference descriptions.
- PlatformKit: removed Gateway-to-inference edges and added audio spectrum telemetry ownership.
- Experience: replaced obsolete orb/emoji and Action-delivered skeleton descriptions; `VoiceOrb.swift` remains a filename, not the current visual design.
- Resources: distinguished active models, diagnostics and comparison-only profiles and removed obsolete artifact-layout wording.

## 2026-09-28 — Documentation ownership

The internal source/target map is now part of [MobileHarness/README.md's Project Structure](../MobileHarness/README.md#project-structure). The unimplemented Photographer concept moved to [Photographer-Proposal.md](Photographer-Proposal.md). [Architecture.md](Architecture.md) now explains the product architecture externally, while source-directory READMEs own current module contracts. Dated UI/build observations moved to [Validation-History.md](Validation-History.md).

The full `docs/` review classified public architecture, roadmap, proposals, validation records, ADR history, original design sources and license notices. Historical technical designs and superseded ADRs now point to later decisions instead of presenting old models, UI, transport or Agent configuration as current. The original Word source and license texts remain unchanged.

## 2026-09-28 — Structured wait documentation audit

Corrected current parser, Agent output and Gateway diagrams to carry typed wait boundaries end to end. Clarified task-local FIFO versus process-wide Channel-name capacity and module exclusion. Updated the future ownership proposal to JSON v4 and a separate resource registry, since task lanes are no longer global. The historical technical baseline and ADR 0015 now explicitly link the superseding scheduling contract; the original Word source remains unchanged. Current acceptance work includes real-model and device validation of nested waits.

## 2026-09-28 — Persistent conversation history

Replaced the standalone raw-output diagnostic with current/past conversation browsing of real Assistant traffic. Storage now retains exact inputs, requests, received fragments and failure state; current context uses ten completed rounds and survives voice sessions/restart. Explicit New Conversation archives atomically, then generates a retryable title. Original historical data that was never saved cannot be reconstructed. See ADR 0060.

## Agent JSON v5 — 2026-09-28

Replaced redundant flat Agent declarations with version/id and Channel-grouped callable Actions. Internal speech, captions, transcript, gaze and overlay behavior now uses code-owned permissions with no model aliases. Tools retain a standard OpenAI function envelope. Shared generation accepts an Agent-owned text mapping, preserving speech/wait order and history previews. See ADR 0061.
