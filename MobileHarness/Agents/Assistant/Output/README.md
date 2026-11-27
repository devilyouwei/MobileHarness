# Assistant output

Everything leaving the Assistant: Action and Tool emission, speech and caption production, Action feedback presentation and playback failures.

While `state.listening` is false, output skips new playback and reply captions. On model entry to quiet, Assistant cancels audio for the initiating input through its speech producer, which joins audio cleanup independently of the generation worker. Normal round settlement records the state control and any admitted Action outcomes.

Native playback registers its audio handle before scheduling PCM. The registration keeps the reply input and session identity through cache revocation and reports audible intervals for perception. Interruption cancels synthesis and revokes handles. Native stop is joined by the scheduled playback Action and confirmed in the execution scope terminal. Playback that exits before the first PCM adds no audible interval.

Emission associates each source-bearing Action with its `callID` and original reply UTF-8 range. The ordered transport submits Actions across channels, and authenticated successful terminal feedback confirms which fragments can be saved after an interruption. Natural-text speech and caption Actions share the same source range.

Assistant confirms both call lanes have opened before submitting a round. Ordinary ActionCalls and `wait` calls enter Action admission in generation order. The Action lane seals after its last admission. The Tool lane seals after its results have been delivered and can seal while Action admission is suspended. Assistant publishes one round terminal after both settlements. Assistant submits Agent publications in channel order and uses concurrent Gateway requests for directed messages, ActionControl and native Tools. [Gateway ordering](../../../Gateway/README.md#signal-channel-ordering)

Action terminal feedback is routed through one entry. It matches the owning round and call before updating the journal. A round that has received its completion receipt enters the dedicated settlement queue by round ID. Action results requiring inference enter the semantic input queue under their derived input ID and can join the next batch. The round ID identifies the model request in history, and the waiting indicator uses its own presentation ID.

| File | Responsibility |
| --- | --- |
| [AssistantChatEmission.swift](AssistantChatEmission.swift) | Output collection, Action and native Tool emission, playback, failures and runtime events. |
| [AssistantChatFeedback.swift](AssistantChatFeedback.swift) | Round Action results, pending feedback acceptance and publication, observation text. |
| [AssistantSpeechOutput.swift](AssistantSpeechOutput.swift) | `AssistantSpeechProducing`, audio-handle production and synthesis/playback presentation. |

Assistant sends pause and resume through `ActionControl` using the active `speak` execution ID from start feedback. It sets volume via the independent `Speech.Playback.setVolume` ActionCall. When voice suppression needs to resume playback, Assistant waits for the matching successful volume Action result before sending resume. Each newly registered playback instance applies the current speech energy from its session, including energy received before a reply starts. State changes and control receipts are separate from Action completion. Paused playback remains active for Decision and cancellation until the native terminal callback.
| [SpeechPlaybackFailure.swift](SpeechPlaybackFailure.swift) | Playback failure value and its presentation. |
