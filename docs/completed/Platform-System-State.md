# Platform system facts for BasicSkill

Status: implemented and reconciled; required automated checks and four Simulator schemes pass. Native-device/system-setting experience acceptance remains separate. Scope approved on 2026-10-25 after checkpoint commit 0fb86445.

## Scope and ownership

Implement eight explicit sources: platform.time, platform.power, platform.thermal, platform.network, platform.permissions, platform.audio, platform.locale and platform.accessibility. BasicSkill selects them through useStates in addition to ui.navigation. Location, motion/activity, proximity, depth, notifications, protected-data, memory-pressure and magnetic attachment remain outside this implementation. No new directory, compilation target, container or third-party dependency is required.

PlatformKit owns public native facts and their observation lifetime. Its neutral PlatformStateReading port returns bounded JSON for an exhaustive PlatformStateSource enum; it imports no project contracts. App injects the port into AgentContainer. An Agents Support adapter registers these capabilities and wraps the returned JSON as ContainerContextValue-compatible availability/value data without base64 conversion. Gateway, Actions and Storage do not participate in these reads. Private Task/Skill state remains in AGENT CONTEXT.

## Files and interfaces

- PlatformKit/Core: add the finite source/reader contract and native system facts. Time reads one injected Date and one time zone per sample, uses a Gregorian calendar and stable English weekday, and includes an offset-bearing timestamp to seconds. Power reads battery level/charge/Low Power Mode; thermal reads the OS enum; locale exposes bounded preferred language/locale/region identifiers; accessibility exposes VoiceOver, reduced motion, closed captions and mono audio. Unsupported/unknown native values remain explicit.
- PlatformKit/Audio: add an application-session observation helper, owned by AudioContainer. Read current route port types and app input-mute state without activation/category changes. Interruption status starts unknown, changes only from observed begin/end events and resets across observation generations. Read microphone permission through AVAudioApplication on iOS.
- PlatformKit/Vision: query camera and Photos add-only/read-write authorization without requesting either permission or camera access.
- PlatformKit/Connectivity: add one NWPathMonitor with a generation-fenced latest snapshot and unknown initial/resumed state. Expose path status/interface types/expensive/constrained and observation time, without endpoint probes. Read Bluetooth authorization statically without creating/scanning a central manager for context.
- PlatformContainer: implement the read port, compose native permission facts and start/stop passive observers with the existing root. Construction is inert; closed roots reject snapshots. A root foreground revision prevents an old asynchronous resume from reopening after a newer invalidation. Foreground suspension fences observations before cancellation; resume creates a fresh observation generation only after prior cleanup. No snapshot starts capture, playback, scanning, permission UI or network requests.
- Agents/Support/AgentPlatformState, AgentContainer and App/Composition: register/inject the finite port; cap native payloads before JSON wrapping. Update BasicSkill revision and teaching without adding a function or execution authority.
- Tests/IntegrationTests: deterministic clock/zone/DST/weekday tests, observation generation/unknown/bounds tests, root admission/lifetime, real context wrapping/refresh and request inclusion. Existing synthetic/provider fixtures explicitly register deterministic platform facts rather than reading the host.

The native adapter lives in Agents/Support beside other SDK adapters. Support/Context remains SDK-independent and consumes only its existing neutral ContainerContextProviding callbacks.

## Native lifetime and bounds

Core battery monitoring is an explicit passive root operation, restored when its owner stops. Audio retains at most two notification observers with synchronous bounded state, no per-event tasks/queue. Network retains one monitor, one latest snapshot and one serial callback queue; stale callbacks cannot publish after invalidation or replacement. Stop cancels the monitor and drains already enqueued callbacks. No event produces a Signal or automatically starts a model decision.

Every source returns at most 8 KiB; the adapter retains existing per-request and combined dynamic block limits. Network observation time describes the last path event, not service reachability. Permission denial is real data, not a collection failure or business grant. Missing battery readings are null/unknown, not zero percent. Native enum additions map to explicit unknown. Raw device/route names, UIDs, SSIDs, IPs, credentials and sensor streams are excluded.

The source boundary checker explicitly classifies AgentPlatformState as a neutral SDK adapter in Support; it must not weaken the SDK-independent Context import rule or the foundation dependency rules.

## Documentation reconciliation

After implementation, update the overall source/assembly figures and source count, PlatformKit/Core/Audio/Vision/Connectivity ownership and lifecycle READMEs, Agents/Context/Assistant and Resources/Skills contracts, App composition and affected test descriptions. Technical READMEs describe implemented behavior only; historical five-source audits remain dated evidence.

## Acceptance

Run focused behavior regressions, source boundary checks, ./scripts/check.sh and ./scripts/build-ios.sh. Preserve failures/limitations explicitly; simulator/fixture checks do not establish real battery, Bluetooth/route, time-zone-change, accessibility or native-device acceptance. Record evidence in docs/validation. Update implementation status only after reconciliation.

[Validation evidence](../validation/Platform-System-State.md) retains iteration failures and final acceptance limits.
