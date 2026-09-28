# Repository structure and target mapping

Purpose: map the target layout in [MobileHarness/README.md](../MobileHarness/README.md) to the current physical source tree and record deliberate exceptions. Runtime algorithms and limits belong in each directory's README; [Architecture.md](Architecture.md) owns cross-module flow.

## Current source ownership

| Physical path | Compiled by | Ownership / layout note |
| --- | --- | --- |
| `MobileHarness/App` | Xcode App targets | Composition, lifecycle and platform/model adaptation |
| `MobileHarness/Experience` | Xcode App targets | SwiftUI presentation, preview and diagnostics |
| `MobileHarness/Gateway` | `Gateway` | Input/output validation, routing and Action scheduling |
| `MobileHarness/AgentCore` | `AgentCore` | Agent identity, communication, generation and output contracts |
| `MobileHarness/Agents` | `Agents` | Assistant, SpeechPerception, VisionPerception and SpeechSynthesis; each Agent's JSON v4 is a SwiftPM resource |
| `MobileHarness/Actions` | `Actions` | Scheduled UI and speech behavior |
| `MobileHarness/ActionRuntime` | `ActionRuntime` | Action registration and execution |
| `MobileHarness/Tools` | `Tools` | Direct System and UI Tool behavior |
| `MobileHarness/ToolRuntime` | `ToolRuntime` | Tool registration and execution |
| `MobileHarness/Storage` | `Storage` | Foundation-only bounded process-local streams and handles |
| `MobileHarness/Storage/Audio` | `StorageAudio` | PCM/Agent identity adapter used by synthesis and playback |
| `MobileHarness/ModelKit` | `ModelKit` plus separate targets | Capability SDK; Defaults, Management, backends and concrete model adapters are excluded from the base target |
| `MobileHarness/PlatformKit` | `PlatformKit` | Device and OS I/O domains |
| `MobileHarness/Resources` | App resource staging | Assets, privacy metadata and model profiles; local weights remain ignored |
| `Tests` | Root SwiftPM test targets | Module and integration tests; shared sources are not copied into test directories |

Root [Package.swift](../Package.swift) maps shared sources to independently tested targets. The Xcode app consumes the root package and compiles only App/Experience sources directly. Do not recreate `Packages/HarnessKit/Sources` or duplicate shared Swift files across App and package targets. The Xcode navigator may reference shared files for browsing; that does not give the App target a second compile membership.

## Documented layout exceptions and pending modules

- A physical parent directory does not imply one Swift target. `ModelKit` is split into its base SDK, `ModelKitRuntime`, `ModelKitDefaults` and concrete adapters/backends. Its current map is in [ModelKit README](../MobileHarness/ModelKit/README.md). `Storage` likewise contains the separate `StorageAudio` target; the former top-level `SpeechRuntime` directory/target was removed by [ADR 0056](adr/0056-storage-audio-migration.md).
- `ActionRuntime` and `ToolRuntime` remain independent directories/targets even though Gateway calls them. This keeps their execution contracts testable without moving shared sources into Gateway.
- Camera pose interpretation is in VisionPerception, while PlatformKit owns camera I/O and Experience owns display. Photographer currently has design documentation only; it does not own the active pose pipeline. See [Agents README](../MobileHarness/Agents/README.md).
- `Character`, ReflexAgent, robot Actions/Tools, general request/reply and durable storage are outstanding. Do not add empty Swift implementations or claim them as active modules. Their delivery status is in [Roadmap.md](Roadmap.md).
- Historical [Tech_Design.md](Tech_Design.md), the original `Technical_Design.docx`, old ADRs and dated validation reports preserve their original context. They are not current target maps.

✅ The current Package/Xcode mapping, Storage split and root Tests placement are documented here. Each implementation directory has its own README for behavior and limits.

❌ Planned domains above are not implemented. Any future directory move must update Package.swift, Xcode navigation, relevant local READMEs and this mapping together.
