# MobileHarness

MobileHarness is an Apple-native Agent harness with the iPhone as its interaction and inference host. Stateful Agent actors receive user input, Tool results and device events through shared gateways. The [technical architecture](MobileHarness/README.md) defines module responsibilities; [repository structure](docs/Repository-Structure.md) records implemented modules and outstanding scope.

The physical-device composition is Nemotron streaming ASR + Silero VAD → AssistantAgent using Qwen3.5-2B MLX ChatCapability → sentence-level say/print ActionCalls → speech and captions. It requires iOS 27 and matching h18p artifacts, with no automatic model fallback. MobileHarnessSimulator is for UI debugging and reports unavailable chat. Models load and warm up before recording. The [Qwen adapter](MobileHarness/ModelKit/Language/LLM/Qwen35/README.md) exposes capabilities independently of business Agents. Camera runs local pose perception and skeleton Tools through VisionPerception; robot control is not implemented.

## Development environment

- Xcode 27+, Swift 6.4+ tooling, Swift 6 language mode.
- App deployment: iOS 27+. The root package's base SDK supports iOS 18+ and macOS 15+.
- MLX requires the Xcode Metal Toolchain component: `xcodebuild -downloadComponent MetalToolchain`.
- Qwen uses separate MLX/Tokenizers dependencies. System TTS uses Apple frameworks. No cloud backend or API key is required; ASR runs locally without automatic network fallback.
- XcodeGen and CocoaPods are not required. The repository uses an explicit toolchain baseline.

## Setup and use

1. Launch Xcode and install the iOS Simulator runtime. Select the full development tools:

   ```sh
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```

2. Open MobileHarness.xcodeproj. Choose MobileHarness for a physical device or MobileHarnessSimulator for UI development.
3. Copy Config/Local.xcconfig.example to ignored Config/Local.xcconfig and supply your development Team ID and Bundle ID.
4. Download physical-device artifacts with `python3 scripts/download-nemotron.py`, `python3 scripts/download-qwen35.py` `python3 scripts/download-kokoro.py` and `python3 scripts/download-yolo26-pose.py`. Simulator ASR uses `python3 scripts/download-audio8.py`. Both configurations require `python3 scripts/download-silero.py`.
5. Tap the central circle, grant microphone permission and speak. After approximately 0.8 s of silence, the final transcript enters the Agent. Tap the circle again to stop recording and playback. The interface provides voice effects and captions without a text input field.

Long utterances are segmented approximately every 12 s while capture continues, then merged into one submission after a pause. Each turn is limited to 60 s. Listening pauses during final recognition/reply handling and resumes after generation and all speech Actions complete. Stop discards unsubmitted content, clears conversation context and cancels inference, queued Actions and playback. Shared ModelManager retains model weights across recording turns and failures; explicit lifecycle operations own unloading.

Nemotron provides live transcript previews. Loading uses an animated ring; listening is blue and speaking is purple with audio-level response. Generated text is progressively segmented by multilingual punctuation, mapped to say/print Actions, and flushed on normal completion. Captions can advance while speech plays; spoken sentences remain sequential. Physical microphone, playback and sustained conversation acceptance follow [Voice validation](docs/Voice.md); successful builds do not establish device quality or stability.

## Validation

```sh
./scripts/check.sh
./scripts/build-ios.sh
```

check.sh runs formatting, Swift Testing and configuration validation. build-ios.sh requires full Xcode and builds five unsigned simulator schemes. `swift test` runs the root package tests directly; opening Package.swift in Xcode also exposes these tests. App schemes provide build/launch; UI automation remains outstanding.

## Repository layout

| Directory | Responsibility |
| --- | --- |
| MobileHarness.xcodeproj | App targets and schemes |
| MobileHarness/App | Entry, composition, AgentBootstrap and lifecycle coordination |
| MobileHarness/Experience | Conversation view/model, voice circle/captions and explicit model diagnostics |
| MobileHarness/Gateway/Input | Model-independent input validation, subscriptions and directed routing |
| MobileHarness/Gateway/Output | Validation, execution routing, dispatch and bounded channel scheduling |
| MobileHarness/AgentCore | Agent contracts, capabilities, Function Token parsing, runtime and ActionCall/ToolCall/ToolResult |
| MobileHarness/Agents | Capability-driven business Agents and JSON registrations |
| MobileHarness/Actions | Cohesive behavior functions: Speech.speak, UI.print and UI.express |
| MobileHarness/ActionRuntime | Explicit executable handler registration and ActionCall execution |
| MobileHarness/Tools and ToolRuntime | Tool functions, registration and execution |
| MobileHarness/ModelKit | Model-driven data processing: typed capabilities, preprocessing/inference/postprocessing and shared model lifecycle |
| MobileHarness/PlatformKit | Device input/output capabilities grouped by Audio, Vision and Connectivity; Core shared contracts |
| MobileHarness/Resources | Privacy declarations, download profiles and ignored model files |
| Tests | Root module and integration tests |
| Config | Shared build configuration and local signing template |
| docs | Architecture, decisions, roadmap and validation records |
| scripts | Artifact downloads, checks and builds |

ModelKit processes supplied data; PlatformKit acquires device data and performs device output. App adapts data and injects services, Gateway controls admission/routing, and Agents own business decisions. For example, TTS produces PCM in ModelKit and a speaker plays it through PlatformKit. See the [responsibility comparison](MobileHarness/README.md#391-platformkit-versus-modelkit).

ModelKit includes ASR, TTS, VAD, LLM, pose and JEV interfaces; Management supplies the separate ModelKitRuntime target. Concrete adapters include Apple speech, Nemotron, Silero, Kokoro, Qwen and YOLO. Backends include CoreAI, CoreML and MLX. SwiftPM compiles the single shared source tree using explicit target paths; tests and dependency boundaries do not require duplicate source directories.

## Kokoro diagnostics

`python3 scripts/download-kokoro.py` downloads pinned Kokoro-82M-CoreAI artifacts (approximately 347 MB). Select KokoroValidation on an iOS 27 device and run Release for English en-US/af_heart playback. Normal Chinese conversation uses system TTS. Mac validation uses `./scripts/test-kokoro.sh`; see [Kokoro validation](docs/Kokoro-Validation.md).

## Documentation and maintenance

Queue algorithms, capacities, overflow policies and cancellation flows belong in each owning directory's README; follow the [concurrency documentation standard](MobileHarness/README.md#concurrency-documentation-standard). SwiftPM excludes module README files from compilation.

- ✅ Capability-based voice pipeline, bounded queues, model adapters and automated checks.
- ❌ Full sustained-device acceptance, robot behavior and UI automation.

See [Architecture](docs/Architecture.md), [ModelKit](MobileHarness/ModelKit/README.md), [Roadmap](docs/Roadmap.md), [Contributing](CONTRIBUTING.md) and [platform boundaries](docs/Platform-Boundaries.md). Preserve docs/Technical_Design.docx as the original design source. Keep documentation aligned with current names and behavior.

The [inter-Agent communication design](MobileHarness/AgentCore/Bus/README.md#inter-agent-communication-design) specifies the planned bounded event/request transport through both gateways. The Bus directory implements event-only transport; its README is excluded from compilation. Request/reply remains deferred.

✅ ModelKitRuntime provides the shared ModelManager: typed capability get, registration lookup, bounded shared loading, unload barriers and terminal shutdown. See [lifecycle design](MobileHarness/ModelKit/Management/README.md). ❌ Timed idle eviction and physical-device retry acceptance remain outstanding.

✅ ModelKit is an internal foundation module built exclusively by root Package.swift. All model contracts and application evaluations live in separate targets under root Tests; boundary checks are enforced by scripts/check.sh.

✅ ModelKitDefaults assembles built-in providers internally; App obtains default capabilities from ModelManager without registering concrete models.

✅ YOLO26n Pose INT8 (end-to-end) provides a separate PoseCapability and Core ML adapter; see MobileHarness/ModelKit/Vision/YOLO/README.md. ❌ Physical-device pose accuracy and robot behavior remain outstanding.

✅ Normal startup requests front-camera preview behind a translucent black overlay, voice orb and captions. Camera controls switch front/back or stop capture; off is black. Camera preview and perception are independent of microphone activation and voice model readiness.

✅ Camera frames now pass a configurable VisionPerception grayscale-change filter (default 3%). VisionPerception runs shared YOLO Pose once per accepted latest frame and emits UI.showPose through direct Tool execution; green skeletons overlay the preview. ❌ Robot-arm control, composition/tracking behavior and device quality acceptance remain outstanding.




✅ Shared perception migration: SpeechPerception owns VAD/ASR and VisionPerception owns camera selection/pose inference. JSON v4 routes observations through OutputGateway → InternalSignalBus → InputGateway; VisionPerception emits skeleton UI Tools directly and Assistant consumes final speech. Photographer is reserved for future camera-motion policy. Gateway has no ModelKit dependency. Voice and camera share the App communication assembly with independent sessions. See [ADR 0040](docs/adr/0040-shared-perception-and-event-routing.md). ❌ Physical-device continuous operation acceptance remains pending.
