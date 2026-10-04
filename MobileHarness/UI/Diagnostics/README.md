# Diagnostics UI

Purpose: show explicitly selected model checks outside ordinary Agent conversation. Design goals: observable status, user controls and no model/player ownership in views.

| File | Responsibility |
| --- | --- |
| SpeechDiagnosticState.swift | Editable text, report and running/stopping values; SpeechDiagnosticControlling declares start/stop |
| MossValidationView.swift | MOSS form and report; delegates synthesis/playback/cleanup to injected controls |
| ChatValidationView.swift | Debug-only result display and a page-scoped task invoking the injected chat check |

## Upstream and downstream

[App composition](../../App/Composition/README.md) creates dependencies and supplies state/operations. [AppWorkflows](../../App/Workflows/README.md) implements both checks; ModelKitDefaults owns provider registration. UI constructs no model session or player.

✅ `-moss-benchmark` opens MOSS Mandarin/English/mixed synthesis and optional playback. Text is editable while idle and disabled during running/stopping. Stop and disappearance request workflow cleanup. The load measurement includes actual synthesis warmup; first PCM, synthesis duration, audio duration and thermal state appear in the report.

✅ `-moss-autorun` runs without playback and writes a report. Adding `-moss-playback` uses the production AppleAudioIO playback path and reports speaker completion only after playback drains. Manual synthesis includes playback. Current evidence and reproduction are in [MOSS validation](../../../docs/Moss-Validation.md).

✅ The existing Debug launch flag `-gemma4-validation` and `GEMMA_VOICE_VALIDATION_*` log markers remain compatible with diagnostic scripts. The operation prepares ASR and the **currently configured chat binding**, then requests a short synthetic arithmetic reply. This is local Gemma 4 E2B by default or the explicitly configured cloud chat provider. It cancels the inference session when the operation exits; it does not explicitly unload chat weights. The page owns the task lifetime and ModelManager owns model residency. It records no microphone audio and executes no Agent Actions.

Conversation history is a normal [Settings](../Settings/README.md) feature, not a diagnostic inference page.

✅ Sources compile in UI; chat validation is Debug-only. No direct model/device imports enter the UI target.

❌ Physical-device editing, playback/route-change acceptance, model coexistence/performance, and prolonged thermal/audio quality verification. A short completion marker establishes generation, not answer quality or device endurance.
