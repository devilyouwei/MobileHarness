# Speech Actions

Purpose: scheduled physical speech playback. Production synthesis is owned by SpeechSynthesisAgent, not by Actions or Gateway.

```mermaid
flowchart LR
    Call[Speech.speak audioID] --> Gateway[OutputGateway validates Action declaration]
    Gateway --> Channel[ChannelScheduler / Speech module]
    Channel --> Playback[SpeechPlayback]
    Playback --> Cache[StorageAudio checkout]
    Cache --> Player[App / PlatformKit continuous player]
    Player --> Done[Hardware drain then release]
```

✅ Production `Speech.speak` accepts only `audioID`. SpeechPlayback validates the audio ID and source/session/input ownership and obtains a single-consumer lease only when scheduled. Initial and intermediate empty PCM reads fail after 3 seconds; known failure/expiry is immediate. Actual playback completion releases cached PCM. Cancellation propagates to the individual synthesis job; input/session cancellation handles pending jobs too.

✅ Gateway has no speech preparation or prevalidation stage. The App output consumer releases source/input audio when dispatch fails, session teardown cancels session audio, and runtime teardown closes the store. SpeechPlayback owns only the scheduled playback operation; its error/cancellation path releases the current audio ID.

✅ Removed the obsolete text-to-synthesis Speak.swift helper. Speech failure, playback cancellation and text-boundary tests now exercise SpeechSynthesisAgent plus audioID playback; there is no legacy synthesis implementation in Actions.

❌ Persistent/repeatable audio and real iPhone latency, Bluetooth and sustained playback acceptance remain outstanding.

## Authoring standard and current exception

Under the [Actions authoring standard](../README.md), `Speech.speak` is a finite operation: completion includes playback drain and audio-lease release. Its current Swift entry is the actor method `SpeechPlayback.play(_:using:)`, not a canonical `SpeechActions.speak(invocation:using:)` entry in Speak.swift. ✅ The actor's existing playback/cache ownership remains implemented. ❌ Namespace/file/signature migration is pending; do not recreate the removed text-to-synthesis helper or change the audioID-only contract while applying this standard.
