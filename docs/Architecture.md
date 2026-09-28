# MobileHarness architecture

MobileHarness turns device signals into Agent decisions and observable actions. An iPhone is the current host: it captures audio and camera frames, runs local perception and language models, and presents speech, captions, eyes and camera overlays. A configured cloud chat provider is optional. The project is designed to add more Agents and external devices, but robot control is not implemented today.

```mermaid
flowchart LR
    World[Microphone / camera / user input] --> Input[Validated input]
    Input --> Perception[Shared speech and vision perception]
    Perception --> Decisions[Assistant and future task Agents]
    Decisions --> Output[Validated actions and tools]
    Output --> Phone[Speech / captions / eyes / camera overlay]
    Perception <--> Models[Local model capabilities]
    Decisions <--> Models
    Decisions -. optional explicit choice .-> Cloud[Cloud chat provider]
```

## How the current system works

- **Perception is shared.** Speech recognition and pose estimation produce observations that other Agents can consume. Camera preview remains available independently of voice-model readiness.
- **Agents decide behavior.** The conversational Assistant handles recognized speech and produces text, speech and presentation requests. An independent synthesis Agent prepares speech audio while playback follows the accepted Action order.
- **Outputs are explicit.** Gateways validate incoming signals and requested behavior. Actions provide scheduled behavior such as speech playback and captions; Tools provide direct functions such as skeleton display.
- **Capabilities stay separate.** ModelKit supplies model processing, PlatformKit handles device input/output, App/Views presents the UI, and App connects those parts. Current speech audio uses a bounded process-local cache; user settings use synchronized cached local persistence. General persistent media and memory remain planned.

The current repository implementation and source-to-target map are documented in the [internal technical plan](../MobileHarness/README.md#project-structure); exact contracts live in the module READMEs linked from its [module design](../MobileHarness/README.md#part-ii--module-design). This page describes behavior and boundaries for external readers; it does not define code-level limits or target dependencies.

## Current scope

✅ Local speech perception, conversational replies, synthesis and playback, camera pose perception, eye expressions/gaze, captions and explicit cloud chat selection have implementation and automated checks. The [voice acceptance guide](Voice.md) and dated validation reports distinguish test evidence from physical-device experience.

❌ Durable memory, general cross-Agent request/reply, robot motion control, continuous background execution and sustained iPhone latency/thermal acceptance remain open. Future work is tracked in the [roadmap](Roadmap.md); historical decisions are in the [ADR index](adr/README.md). Physical robot safety would have to be enforced by the external controller, not by an iPhone App remaining active in the background.

User settings persist on this device, while credentials remain in protected device storage. The current design does not synchronize settings across devices. [ADR 0057](adr/0057-local-settings-storage.md) records the storage decision; the [Storage README](../MobileHarness/Storage/README.md) owns the implementation contract.


Default speech now uses local MOSS-TTS-Nano Core ML (beta) behind the same capability and audio-cache boundary. Kokoro is no longer selected or packaged, following repeated device crashes. [ADR 0058](adr/0058-moss-tts-nano.md) records the replacement; device acceptance remains pending.

Cloud settings allow blank credentials and an omitted endpoint (official OpenAI URL fallback). Registration remains local; authentication and provider compatibility errors surface during discovery or generation. See the updated [ADR 0053](adr/0053-settings-live-chat.md).

StorageAudio production PCM cache defaults to 8 MiB per handle (32 live handles; 256 MiB aggregate PCM ceiling, allocated on demand). This matches the synthesis Agent’s per-request output limit and accommodates approximately 43.7 seconds of MOSS 48 kHz mono Float32 audio. Overflow remains explicit; see ADR 0058.

Settings includes [conversation history](../MobileHarness/App/Views/Settings/README.md) for actual Assistant exchanges. It preserves original user text, received model fragments, exact request context and error status in local durable storage. Current conversation context uses its latest ten completed rounds across voice sessions and App restarts. Start New archives it, creates an empty context and generates an archived title; pending titles can be retried. Stored markup is inspected without execution. This replaces the former single-turn raw-output test; it helps inspect wait failures but does not prove scheduler timing. See [ADR 0060](adr/0060-persistent-conversation-history.md).


Action scheduling now uses task-local nested wait groups: each wait joins its parent's prefix, preserves Channel FIFO/concurrency internally, and releases the parent's suffix only after closure and completion. Equal Channel names no longer imply a shared cross-task FIFO; device-module exclusion remains process-wide. [ADR 0059](adr/0059-structured-wait-scheduling.md) records the protocol and migration. Tools and speech synthesis prefetch remain outside these Action groups.

## Agent configuration and internal behavior

✅ JSON v5 declares model-callable Actions grouped by Channel, native function Tools and unchanged communication policy. Fixed speech/caption/transcript/gaze/overlay behaviors and their permissions are code-owned. Model parsers cannot resolve internal operations; all outputs still cross OutputGateway. See [ADR 0061](adr/0061-agent-json-v5.md). ❌ Full JSON Schema and provider-native Tool deltas remain unimplemented.

ChatRequest output budgets are optional: normal Assistant calls omit max_tokens for provider defaults; local Qwen bounds generation by remaining context. Historical explicit budgets remain readable. Parser and execution capacity limits still apply.

## Source ownership

Actions and Tools each include their Runtime subdirectory in a single compilation target. Shared contracts live in Agents/Core but retain the independent AgentCore target to preserve acyclic StorageAudio/Gateway dependencies. SwiftUI presentation is under App/Views. Runtime flow and behavior are unchanged; see [ADR 0063](adr/0063-module-directory-consolidation.md).
