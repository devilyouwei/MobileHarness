# Assistant output

Everything leaving the Assistant: Action and Tool emission, speech and caption production, Action feedback presentation and playback failures.

While `state.listening` is false, output skips new playback and reply captions. On model entry to quiet, Assistant cancels audio for the initiating input through its speech producer, which joins audio cleanup independently of the generation worker. Normal round settlement records the state control and any admitted Action outcomes.

Native playback registers its audio handle before scheduling PCM. The registration keeps the reply input and session identity through cache revocation and reports audible intervals for perception. Interruption cancels synthesis and revokes handles. Native stop is joined by the scheduled playback Action and confirmed in the execution scope terminal. Playback that exits before the first PCM adds no audible interval.

For tracked model replies, the speech producer uses the shared sentence splitter within each decoded `speak`. Each unit gets its own synthesis request and the whole Action uses one PCM stream. The producer holds at most the last frame of the current unit until synthesis has confirmed its terminal. Its callback records native completion against that unit. The 8 MiB PCM budget applies across all units of the Action.

| File | Responsibility |
| --- | --- |
| [AssistantChatEmission.swift](AssistantChatEmission.swift) | Output collection, Action and native Tool emission, playback, failures and runtime events. |
| [AssistantChatFeedback.swift](AssistantChatFeedback.swift) | Round Action results, pending feedback acceptance and publication, observation text. |
| [AssistantSpeechOutput.swift](AssistantSpeechOutput.swift) | `AssistantSpeechProducing`, audio-handle production and synthesis/playback presentation. |
| [SpeechPlaybackFailure.swift](SpeechPlaybackFailure.swift) | Playback failure value and its presentation. |
