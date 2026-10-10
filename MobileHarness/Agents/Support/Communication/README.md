# Shared business communication contracts

Purpose: define immutable application Signal values, schema/catalog assembly and bundled configuration loading shared by Agents and App/Gateway adapters. Compiles in the existing Agents target with Foundation/AgentCore. Generic messaging/authorization protocols belong to [Core/Communication](../Core/Communication/README.md).

| File | Responsibility |
| --- | --- |
| AgentConfigurations.swift | Load bounded JSON v6 resources from Bundle.module and validate the business catalog; fail missing/invalid configuration explicitly |
| AgentContracts.swift | Built-in application identities, PerceptionMessage wrappers, typed factories/access, small history/session controls and schema catalog assembly |
| AgentTasks.swift | Public task content/views, capability overview, trusted fixed-intent unwrapping and explicit scoped user replies |
| ApplicationSignals.swift | Application environment facts and device/navigation intent values/validation |
| ModelResourceSignals.swift | Resource intents/observations and owner-correlated host-failure values |
| ProviderIntents.swift | Provider settings/discovery intent values |
| PhotographerCameraIntent.swift | Typed camera operation, facing and artifact identity validation |
| SpeechValues.swift | Speech phase and synthesis input values |
| PoseObservation.swift / SoundSourceObservation.swift | Bounded perception values and validation |

✅ ADR0189: the former Agents/Communication directory and shared AgentConfigurations now live here. Type names, Codable schemas, permissions, byte limits and freshness policies are unchanged. Configuration resources remain in their seven role directories. No role processing, worker, retry, model/device effect or transport implementation moves here.

Upstream: role output/input adapters and App typed intent producers. Downstream: neutral Core AgentMessage/CommunicationContracts, configuration validation and injected Gateway routing policy. The catalog supplies business schemas; Gateway supplies trusted runtime identity and admission; each receiving Agent owns business processing.

Input factories preserve provenance/root/parent/session. Runtime feedback authority cannot be supplied by model or user content. Domain validation rejects unknown content, malformed identities, forbidden fields and oversized encoded payloads. TaskRequest/Input/Progress/Result/Cancel retain explicit scopes; admission receipt is separate from final completion. Task messages are directed. Fixed UI intent unwrapping requires trusted Assistant/task provenance; models cannot construct a trusted UI command or confirmation.

Speech/pose observations inherit causal freshness; sound source is500ms, pose1s and partial transcript2s. Synthesis/cancellation and work intents have fresh bounded admission. Camera/history/provider payloads retain512-byte schema bounds; resource/application intent bounds remain in their declared schemas. Task user text is bounded4096 bytes; generic task metadata remains in Core. Queues, consumption, persistence, cancellation and recovery policy belong to Agents/runtime, not these immutable contracts.

✅ Source relocation and cross-Agent task contracts are implemented. ❌ Durable/remote transport, richer memory schemas and real-model/native-UI/device acceptance remain outstanding. See [Support](../README.md), [Agents](../../README.md), [ADR0189](../../../../docs/adr/0189-agent-support-hierarchy.md) and [validation](../../../../docs/Validation-History.md).

## Listening policy ownership

✅ ApplicationSignals.swift defines speech.listening user intent, interaction.replyActivity complete bounded occupancy snapshots and speech.captureEnded revision-fenced native termination. AgentContracts.swift validates these schemas; JSON declares publishers and subscriptions. ReplyActivity carries up to128 input/task IDs each, source-local revision and acknowledged causal root; no device policy appears in the value.

❌ True-device acoustic echo, tail, route/interruption and native UI acceptance remain pending.



✅ AgentCapabilityCatalog explains new-task kind=request with a concrete Photographer example; kind=task is invalid, and existing task input/cancellation requires taskID. Model exposure and correction belong to Support/Chat; fixed publication and transport remain independent.



✅ Shared Action registration: Action implementations support many-to-many Agent registration. ApplicationControl registers the 11 Robot Actions for Settings command tests. Assistant retains basic interaction registration; Photographer retains camera-only model permissions. Each role calls canonical functions under its own identity; no inter-Agent delegation is needed to reuse an Action.


✅ Reply/lifecycle regression correction: caption focus is presentation only and cannot cancel an authorized queued/playing reply from another Agent. Playback checks active session and explicit task cancellation, retaining Gateway owner/task/function authorization and the shared serialized Speech Channel. ApplicationControl accepts environment facts and correlated feedback while paused; fresh business commands still require running. Assistant delegation prompts emit send without redundant spoken acknowledgments and leave specialist speech to its executor. Scope/result delivery failures retain actual evidence; no silent error suppression or action replay is added. Add owner-switch playback admission and paused environment regressions.


✅ Camera perception/context change (2026-10-10): PhotographerCameraIntent.swift also defines bounded camera.state snapshots: monotonic sequence, sample time, enabled/visible/busy/permission flags, lens, displayed/saved photo identities and bounded native errors. AgentContracts registers the passive fact schema; Photographer JSON grants only phone.camera subscription. Root session is fenced by the Signal envelope. No task or transport receipt is created.
