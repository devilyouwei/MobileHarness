# Default model assembly

Purpose: select and register the project's concrete model providers inside ModelKit. Design goals: one default per capability, deferred weights, explicit platform availability and no business dependency.

| Capability | Default |
| --- | --- |
| Chat | Gemma 4 E2B QAT CoreAI from Gemma4 |
| Recognition | Installed Nemotron → Apple SpeechAnalyzer / SpeechTranscriber |
| Voice activity | Installed Silero → EnergyVoiceActivity |
| Synthesis | Installed MOSS-TTS-Nano → Apple AVSpeechSynthesizer |

Speech defaults are stable capability facades. Explicit ModelKitDefaults.mossNano returns the concrete local provider; the default synthesis facade selects it only when installed and available. Apple speech and energy VAD are registered lazily. Kokoro is not registered. Judgment has no provider and fails with missingDefault. Simulator local chat reports unavailable; Nemotron uses the same Core ML resource layout on Apple Silicon macOS and iOS; explicit cloud chat configuration is supported.

ModelKitDefaults.manager(resources:) registers factories without loading weights. App supplies the sandbox installed resource root, obtains interfaces through manager.get(.chat), and forwards platform memory warnings. The Defaults target depends on management and adapters; ModelKitRuntime depends only on ModelKit. Models with large local weights opt into idle release on memory pressure.

```mermaid
flowchart LR
    App -->|Resource root| Defaults[ModelKitDefaults]
    Defaults -->|Factories and default capabilities| Manager[ModelManager]
    Defaults --> Adapters[Concrete adapters]
    App -->|get capability| Manager
    Manager -->|Shared interface| App
```

- ✅ Internal registration and artifact-aware speech selection; diagnostics use the same selected synthesis as conversation.
- ✅ Lazy resource loading, fail-fast registration and teardown on assembly failure.
- ❌ Judgment provider and automatic fallback after an active inference fails.

## Process-wide ownership and admission

The first manager(resources:cloudChat:) call fixes the canonical resource root and initial cloud configuration and stores one assembly task before suspension. Concurrent callers join that task (at most 32 waiting callers; overflow throws inputBusy). Equivalent paths share the manager; another root throws resourceDirectoryConflict. Caller cancellation never cancels shared assembly. Assembly failure is retained and propagated; no alternate manager or implicit retry is created. Shutdown is terminal for this process; later access returns the same closed manager.

ModelManager construction and registration are ModelAssembly SPI, reserved for this assembly and isolated tests. Production consumers use this shared entry or injected capabilities. Each model resource admits one operation; overlapping requests fail with inputBusy. Explicit session cancellation requests cleanup, and admission remains occupied until cleanup releases the lease. There is no request waiting queue or automatic preemption. Different model types retain independent admission so VAD and ASR can cooperate during recording.

```mermaid
flowchart TD
    Call[Modules request manager] --> Root{Same resource root?}
    Root -->|No| Error[Configuration error]
    Root -->|Yes / first call| Task[One retained assembly task]
    Task --> Manager[One process manager]
    Manager --> Provider[One provider per registered model]
    Provider --> Busy{Operation active?}
    Busy -->|Yes| Reject[inputBusy]
    Busy -->|No| Run[Reserve lease and run]
    Run --> Clean[Finish or cancel and clean up]
    Clean --> Release[Release lease]
```

- ✅ Process-wide manager, bounded concurrent assembly access and terminal shutdown.
- ✅ One operation per model including system speech; cancellation preserves cleanup ordering.
- ❌ Global scheduling across different model types and automatic preemption.

✅ `.pose` binds yolo26n-pose through ModelKitYOLOPose with releaseWhenIdle, loading YOLOPose under the supplied resource root. Registration remains lazy; voice startup does not request pose. ✅ Pose weights are acquired through Settings and loaded from the sandbox; App staging contains metadata only.

✅ Default .pose now resolves exclusively to ModelID("yolo26n-pose") and the new official end-to-end artifact. Singleton and releaseWhenIdle ownership remain unchanged; no YOLOv8 registration/fallback remains.

✅ `manager(resources:cloudChat:)` optionally selects OpenAI-compatible cloud chat, including on simulator, without loading Gemma 4 E2B or warming the remote service. Omission preserves local defaults. An explicit conflicting initial cloudChat throws `cloudConfigurationConflict`; ordinary manager(resources:) access uses the current configuration. Explicit updates use configureChat and preserve the resource root. App owns Keychain persistence and settings UI.

✅ configureChat(resources:configuration:) explicitly replaces the chat registration in the existing process manager. A nil configuration restores local Gemma 4 E2B. Ordinary manager(resources:) access now obtains the current process binding without resetting it. Explicit initial cloudChat still validates conflicts. App pauses its active voice session and resolves a fresh capability per operation. This supersedes the earlier restart-only limitation. ❌ Network/model availability is not verified by replacement itself.

✅ Explicit voice admission/diagnostics perform real in-memory synthesis warmup before conversation admission or measured speech. It exercises lazy kernels using synthetic Chinese text, drains PCM without playback and propagates failures. The first device run took 10.63 s to first PCM without warmup; explicit voice admission absorbs that compilation cost instead of extending StorageAudio timeouts. ❌ Warmup does not prove sustained runtime stability.

## Artifact-aware assembly

✅ Local registrations associate with bundled artifact IDs; cloud chat has no Gemma 4 E2B download requirement. configureArtifacts receives App-supplied source catalog, storage and concrete downloader protocols through Defaults, validates associations and is idempotent for matching IDs/revisions/directories. App does not import ModelAssembly SPI. Defaults preserves one process manager and Swift-owned factories/bindings; JSON never registers executable providers. Factories use stable sandbox installed directory URLs. Deletion/reinstallation uses Management maintenance; YOLO selects its available format on each reload.

✅ App injects ModelKitHub as the concrete HF SDK adapter. ModelKitRuntime depends only on ModelKit, and neither Defaults nor Management imports Storage. Initialization does not warm models; explicit voice start or diagnostics performs warmup.

❌ Automatic variant/revision activation, runtime-error fallback and guaranteed server resume remain pending. See [Management](../Management/README.md#local-model-resources--current-contract).

## Speech selection

✅ configureSpeech(recognition:synthesis:) controls two independent choices, initially false. Custom recognition requires installed Nemotron; custom synthesis requires installed MOSS. VAD automatically selects installed available Silero, otherwise Energy, irrespective of either preference. Each operation selects once: enabled, installed and available ASR/TTS provider, otherwise Apple ASR/TTS. Disabling one choice preserves artifacts and does not affect the other speech choice or chat/pose. Errors during an active operation propagate; no mid-session provider replacement or hidden cloud inference occurs. App pauses voice before applying a changed preference and restores it before constructing the conversation container.

Apple ASR uses iOS/macOS 26+ SpeechAnalyzer and SpeechTranscriber with a medium-sensitivity SpeechDetector in the same analyzer. The native detector performs internal voice gating; normal activity results are not publicly usable in current runtime tests, so installed available Silero, otherwise Energy, supplies business silence-endpoint scores independently of the ASR choice. Explicit warmup installs missing language assets through AssetInventory; those assets are managed by Apple rather than the HF artifact store. Unsupported hardware/language remains an observable availability error. Energy VAD emits thresholded acoustic activity when Silero is unavailable; SpeechPerception owns onset, pre-roll, 800 ms silence and 12 s chunk limits.

```mermaid
flowchart LR
    Settings[Persisted ASR/TTS preferences] --> Speech[ASR/TTS policy]
    Receipts[Management installation snapshots] --> Speech
    Receipts --> VAD[VAD policy independent of switches]
    Speech --> Local[Enabled installed available Nemotron / MOSS]
    Speech --> System[Apple ASR / Apple TTS]
    VAD --> Silero[Installed available Silero]
    VAD --> Energy[Otherwise Energy]
    Local --> Session[One selected provider per operation]
    System --> Session
    Silero --> Session
    Energy --> Session
```

✅ Capability failures retain typed CapabilityError/CapabilityAvailability outcomes with neutral technical diagnostics. User-facing localization, retry guidance and settings instructions belong to consumers. ❌ No presentation policy is introduced into this adapter.
