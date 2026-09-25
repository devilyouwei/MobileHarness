# ADR 0021: Remove Obsolete Voice Paths

Status: accepted. Date: 2026-09-24.

The App uses continuous resampling, neural VAD and LiveSpeechInput. Remove the superseded energy VoiceSegmenter, batch MonoPCMResampler, VoiceInputSession and InputGateway batch recognition methods. Preserve MicrophoneFrame as its own file and move conversion errors into StreamingMonoPCMResampler.

VoiceActivitySegmenter now emits only audio/end stream events. Its boundary policy retains pre-roll and uncommitted silence, without duplicating full utterances. App determines turn completion from end events. The 12-second model chunk, 800-ms endpoint, 60-second turn limit and cancellation semantics remain unchanged.

Remove unreachable manual finish/text-send UI controls, unused status forwarding and the unread entries buffer. Private OSLog messages replace that buffer; current error presentation and voice cancellation remain. Assistant requires ChatCapability; fixed replies are standard capability doubles under Tests, not production constructor options.

Migrate behavioral tests to the live path and record expected sample identity through chunk boundaries, internal pauses and endpoint padding. Remove only tests specific to the deleted energy algorithm. Preserve independent adapters, ToolCallParser and future-facing public capability contracts.

This intentionally removes obsolete public batch APIs from the workspace package; external clients, if any, must migrate to live sessions. No external compatibility guarantee has been established. Real microphone and playback acceptance remains a separate device check.

Validation completed: root check, five simulator builds and unsigned device Debug compilation passed. Integration tests now total 47 after removing three obsolete energy-VAD tests; live-path regressions and neural boundary-policy tests pass. Opt-in real-model/audio tests and physical device acceptance were not run.
