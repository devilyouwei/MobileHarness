# Assistant output

Everything leaving the Assistant: Action and Tool emission, speech and caption production, Action feedback presentation and playback failures.

| File | Responsibility |
| --- | --- |
| [AssistantChatEmission.swift](AssistantChatEmission.swift) | Output collection, Action and native Tool emission, playback, failures and runtime events. |
| [AssistantChatFeedback.swift](AssistantChatFeedback.swift) | Round Action results, pending feedback acceptance and publication, observation text. |
| [AssistantSpeechOutput.swift](AssistantSpeechOutput.swift) | `AssistantSpeechProducing`, audio-handle production and synthesis/playback presentation. |
| [SpeechPlaybackFailure.swift](SpeechPlaybackFailure.swift) | Playback failure value and its presentation. |
