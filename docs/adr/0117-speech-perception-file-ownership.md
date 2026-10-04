# ADR 0117: SpeechPerception file ownership

Status: accepted

## Context and decision

SpeechPerception coordinates one utterance across VAD and ASR chunks. Keep its mutable lifecycle, input gate, utterance identity and output authority in one Agent actor. Split pure boundary policy and transcript accumulation into internal value types; name the internal per-utterance ASR actor SpeechRecognitionTurn. The public segmentation interface remains available to existing consumers. No helper imports AgentCore, Gateway, App, UI or PlatformKit.

Agent methods explicitly separate frame processing, utterance completion, listening reset and failure cleanup. One phase transition method assigns state and requests presentation, and explicitly chooses whether to publish an observation. Normal phase transitions publish; resume and final-delivery recovery retain presentation-only behavior. Processing now updates retained phase state as well as emitted presentation. Empty denotes an emitted outcome normalized to listening in retained state and presentation; awaitingReply owns admission independently.

Boundary padding uses sample budgets with whole-window selection, preserving standard 512-sample windows and bounding padding for variable windows. Transcript rejection is transactional; obsolete revisions and final-segment revisions cannot modify accumulated text. Existing queue/timeout/turn limits, final delivery requirements and reply gating remain.

## Consequences and validation

✅ ASR session ownership, pure text policy, VAD adaptation and pure boundary policy have separate files. Output and cancellation authority remain centralized. Helper import boundaries are checked by the repository script; revision/overflow and variable-window padding have targeted regression tests.

❌ Barge-in, background listening and real-device sustained recognition acceptance remain outstanding. Full repository and iOS build results are reported separately; no device inference is claimed by fixture tests.
