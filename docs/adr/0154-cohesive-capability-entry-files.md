# ADR 0154 — Cohesive capability entry files

Date: 2026-10-06. Status: source layout implemented; addressing migration pending.

## Decision

Refine the [staged design](../../MobileHarness/README.md#ownership-and-compilation) before moving code. Split callable functions into cohesive module files under their business-domain directory. Domain Actions enums remain used namespace facades; implementations extend those enums, preserving existing API names and generated factories without forwarding wrappers. Domain catalogs remain the registration owners.

UI: Expression, Gaze, Caption, VoiceState, Pose, HistoryPresentation. NexArm: Motion, Gesture, Tracking. Speech: Playback. Camera: Capture. History: Conversation. System: Runtime. Private helpers move with consumers; shared domain helpers retain their visibility. SpeechActionError belongs in Speech/Support/SpeechTypes.swift.

## Status

✅ One copy of each function, body and metadata remains. Boundary checks enforce domain/module-file/function ownership and prohibit public callable bodies in facades. No scheduling, resources, permissions, signature or feedback policy changes.
❌ Three-field path values, versioned configuration and registry migration remain pending. Filenames do not implicitly authorize or resolve new paths; legacy identifiers remain active until coordinated migration.

Validation belongs to Validation-History.
