# Architecture decisions

ADRs retain the context, decision and consequences at their recorded date. Read each record's status and supersession notes; an accepted historical decision does not make its original API, model or limits current.

Current dependencies and flows belong to the [technical design](../../MobileHarness/README.md); module READMEs own current contracts. [Roadmap](../Roadmap.md) owns pending work and [validation](../README.md#experiments-tests-and-acceptance) owns experimental evidence.

✅ Decisions are indexed by their stable number below.

❌ Superseded records are historical evidence rather than current implementation requirements.

| ID | Decision |
| --- | --- |
| 0001 | [ADR 0001 原生模块化 Runtime](0001-native-modular-runtime.md) |
| 0002 | [ADR 0002 模型能力与后端解耦](0002-model-capabilities.md) |
| 0003 | [ADR 0003 能力 SDK 与应用组装的编译边界](0003-capability-sdk-boundary.md) |
| 0004 | [ADR 0004 系统语音网关闭环](0004-system-voice-loop.md) |
| 0005 | [ADR 0005 按技术方案整理源码目录](0005-design-aligned-layout.md) |
| 0006 | [ADR 0006 Nemotron 流式 ASR 与模型层目录纠正](0006-nemotron-streaming-asr.md) |
| 0007 | [ADR 0007 App 使用 Nemotron ASR](0007-nemotron-app-binding.md) |
| 0008 | [ADR 0008 Silero VAD capability 与输入分段](0008-silero-vad.md) |
| 0009 | [ADR 0009 Audio8 原生 ASR adapter](0009-audio8-asr.md) |
| 0010 | [ADR 0010 默认语音切换为 Audio8 + Silero](0010-audio8-app-binding.md) |
| 0011 | [ADR 0011 有界长句识别与结束语义](0011-voice-turn-segmentation.md) |
| 0012 | [ADR 0012：实时语音预览与圆环交互](0012-live-voice-orb.md) |
| 0015 | [0015 · 分句 FunctionToken 与共享 Actions](0015-function-actions.md) |
| 0016 | [ADR 0016 — Kokoro CoreAI 独立验证](0016-kokoro-validation.md) |
| 0017 | [ADR 0017 · 新设计第一阶段：入口到 Gateway](0017-entry-gateway-migration.md) |
| 0018 | [ADR 0018 · Agent 内双协议解析与 Channel 调度](0018-agent-protocols.md) |
| 0019 | [ADR 0019 · Agent 独立 plist 配置与统一开发规范](0019-agent-configuration.md) |
| 0020 | [ADR 0020：按正式 README 对齐实现目录与命名](0020-layout-alignment.md) |
| 0021 | [ADR 0021: Remove Obsolete Voice Paths](0021-remove-obsolete-voice-paths.md) |
| 0022 | [ADR 0022: JSON Capability Configuration v2](0022-json-capability-configuration.md) |
| 0023 | [ADR 0023: Function Documentation and Model Visibility](0023-capability-doc-visibility.md) |
| 0024 | [ADR 0024: Present expressions independently from captions](0024-orb-expressions.md) |
| 0025 | [ADR 0025: One parameterized expression Action](0025-unified-expressions.md) |
| 0026 | [ADR 0026: Separate Action guidance from native tools](0026-action-only-system-context.md) |
| 0027 | [ADR 0027 — Qwen3.5 chat through MLX](0027-qwen35-mlx-chat.md) |
| 0028 | [0028 — Gateway-mediated Internal Agent Communication](0028-inter-agent-communication.md) |
| 0029 | [0029 — Exclusive Channel Ownership](0029-channel-lock.md) |
| 0030 | [0030 — Shared Model Manager](0030-shared-model-manager.md) |
| 0031 | [ADR 0031: Fixed local model resources](0031-fixed-local-model-resources.md) |
| 0032 | [ADR 0032: ModelKit management and memory policy](0032-modelkit-admission-and-memory-policy.md) |
| 0033 | [ADR 0033: ModelKit inside the project](0033-modelkit-project-boundary.md) |
| 0034 | [ADR 0034: Internal default model assembly](0034-modelkit-default-assembly.md) |
| 0035 | [ADR 0035: YOLOv8 Pose capability](0035-yolov8-pose.md) |
| 0036 | [ADR 0036: Changed camera frames → Photographer → skeleton Action](0036-photographer-pipeline.md) |
| 0037 | [ADR 0037 — Native camera frames and Vision pose inference](0037-native-vision-pose.md) |
| 0038 | [ADR 0038 — Replace YOLOv8 with YOLO26n-Pose](0038-yolo26-pose.md) |
| 0039 | [ADR 0039 — Platform Capability Domains](0039-platform-capability-domains.md) |
| 0040 | [ADR 0040 — Pure Gateway and shared perception](0040-shared-perception-and-event-routing.md) |
| 0041 | [ADR 0041 — Vision Perception Owns Skeleton Visualization](0041-vision-perception-skeleton-action.md) |
| 0042 | [ADR 0042 — ShowPose as a Completion-Only Tool](0042-show-pose-completion-tool.md) |
| 0043 | [ADR 0043 — Conversation turn presentation](0043-conversation-turn-presentation.md) |
| 0044 | [ADR 0044 — Bounded Visual Freshness](0044-visual-freshness.md) |
| 0045 | [ADR 0045 — Audio spectrum telemetry](0045-audio-spectrum-telemetry.md) |
| 0046 | [ADR 0046 — Semantic eye expressions](0046-semantic-eye-expressions.md) |
| 0047 | [ADR 0047 — Explicit input routing](0047-explicit-input-routing.md) |
| 0048 | [ADR 0048 — Direct signal admission and Agent-owned inboxes](0048-direct-signal-admission.md) |
| 0049 | [ADR 0049 — Perception-driven eye gaze](0049-perception-eye-gaze.md) |
| 0050 | [0050 — Default Kokoro synthesis](0050-default-kokoro-synthesis.md) |
| 0051 | [ADR 0051: OpenAI-compatible cloud chat](0051-openai-compatible-chat.md) |
| 0052 | [0052 — Local Kokoro Core ML bilingual synthesis](0052-kokoro-coreml-bilingual.md) |
| 0053 | [ADR 0053: Settings and immediate chat selection](0053-settings-live-chat.md) |
| 0055 | [ADR 0055 — Directed synthesis Agent and transient audio handles](0055-synthesis-agent-audio-handles.md) |
| 0056 | [ADR 0056 — Shared Storage core and PCM adapter](0056-storage-audio-migration.md) |
| 0057 | [ADR 0057: Local settings persistence and cache synchronization](0057-local-settings-storage.md) |
| 0058 | [0058 — Replace default Kokoro with MOSS-TTS-Nano](0058-moss-tts-nano.md) |
| 0059 | [ADR 0059 — Structured wait groups for Action scheduling](0059-structured-wait-scheduling.md) |
| 0060 | [ADR 0060 — Persistent conversation history and explicit conversation boundaries](0060-persistent-conversation-history.md) |
| 0061 | [ADR 0061 — Channel-grouped model catalogs and code-owned internal behavior](0061-agent-json-v5.md) |
| 0062 | [ADR 0062 — Optional chat output-token budgets](0062-default-chat-output-budget.md) |
| 0063 | [ADR 0063 — Consolidate behavior runtimes, Agent source ownership and App views](0063-module-directory-consolidation.md) |
| 0064 | [ADR 0064 — Separate App ownership and UI](0064-app-ui-boundaries.md) |
| 0065 | [ADR 0065 — Action implementation contracts and execution diagnostics](0065-action-runtime-contracts.md) |
| 0066 | [ADR 0066 — Action terminal feedback and resource leases](0066-action-results-resource-leases.md) |
| 0067 | [ADR 0067 — Domain-owned behavior definitions and capability assembly](0067-domain-owned-behavior-assembly.md) |
| 0068 | [ADR 0068 — Canonical Action entry points](0068-canonical-action-entrypoints.md) |
| 0069 | [ADR 0069 — Storage core and domain directories](0069-storage-core-domain-layout.md) |
| 0070 | [ADR 0070 — NexArm supervised USB Action](0070-nexarm-usb-diagnostic.md) |
| 0071 | [ADR 0071 — Foreground iPhone NexArm BLE](0071-nexarm-iphone-ble.md) |
| 0072 | [ADR 0072 — Bounded NexArm entertainment skills](0072-nexarm-entertainment-skills.md) |
| 0073 | [ADR 0073 — Peripheral detail controls](0073-peripheral-detail-controls.md) |
| 0074 | [ADR 0074 — NexArm live joystick control](0074-nexarm-live-jog.md) |
| 0075 | [0075 — Fixed NexArm choreography](0075-nexarm-fixed-choreography.md) |
| 0076 | [0076 — NexArm controller preset transport](0076-nexarm-controller-preset-transport.md) |
| 0077 | [0077 — Calibrated physical pose choreography](0077-nexarm-calibrated-pose-choreography.md) |
| 0078 | [0078 — Shared NexArm controller and physical validation](0078-nexarm-shared-physical-validation.md) |
| 0079 | [0079 — Continuous NexArm manual jog](0079-nexarm-smooth-jog.md) |
| 0080 | [0080 — Independent NexArm motion results](0080-nexarm-independent-motion-results.md) |
| 0081 | [0081 — Settings immediate test control](0081-settings-immediate-test-control.md) |
| 0082 | [0082 — NexArm channel observation and host watchdogs](0082-nexarm-observation-watchdogs.md) |
| 0083 | [0083 — Unified Action execution presentation](0083-action-execution-presentation.md) |
| 0084 | [ADR 0084 — LLM output buffering](0084-llm-output-buffering.md) |
| 0085 | [ADR 0085 — Reply-owned speech audio](0085-reply-owned-speech-audio.md) |
| 0086 | [ADR 0086 — Domain-owned Action display metadata](0086-action-display-metadata.md) |
| 0087 | [ADR 0087 — Producer-owned speech deadline](0087-speech-producer-deadline.md) |
| 0088 | [0088 — Settings-matched NexArm Cartesian playback](0088-nexarm-settings-matched-playback.md) |
| 0089 | [ADR 0089 — NexArm performance completion covers arm axes](0089-nexarm-arm-completion-scope.md) |
| 0090 | [ADR 0090 — NexArm gestures and home never address the gripper](0090-nexarm-arm-only-motion-packets.md) |
| 0091 | [0091 — NexArm motor-scoped feedback execution](0091-nexarm-motor-scoped-feedback.md) |
| 0092 | [0092 — Atomic actions and composed results](0092-atomic-actions-and-composed-results.md) |
| 0093 | [ADR0093 — NexArm PlatformKit and Action boundary](0093-nexarm-platform-action-boundary.md) |
| 0094 | [ADR0094 — Arrival profiles, dynamic execution budgets and behavior macros](0094-arrival-profiles-and-behavior-macros.md) |
| 0095 | [ADR0095 — Remove retired device and behavior code](0095-remove-retired-device-and-behavior-code.md) |
| 0096 | [ADR 0096 — Behavior-owned execution contracts](0096-behavior-owned-contracts.md) |
| 0097 | [ADR 0097 — Opaque source identity for audio storage](0097-storage-audio-opaque-owner.md) |
| 0098 | [ADR 0098 — Independent runtime, workflow and audio boundaries](0098-independent-runtime-workflow-audio-boundaries.md) |
| 0099 | [ADR0099 — Shared Types grouped by category](0099-shared-types-layout.md) |

| 0100 | [ADR0100 — Camera control Tools reuse the App owner](0100-camera-control-tools.md) |

| 0101 | [ADR0101 — Cloud native Tool calls](0101-cloud-native-tool-calls.md) |

✅ [0102 — Photographer aim on shared pose](0102-photographer-aim.md) keeps aim business policy in Actions and independent ToolRuntime dispatch. ❌ Physical tracking acceptance remains pending.

✅ [0103 — Agent failure isolation](0103-agent-failure-isolation.md) defines nonfatal messaging/execution outcomes and Photographer offline suppression. ❌ Sustained device acceptance remains pending.
