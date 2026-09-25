# Architecture decisions

Purpose: preserve the reason, scope and consequences of implementation decisions.

✅ Numbered ADRs record staged architecture evolution; 0027 selects the Qwen3.5 MLX chat adapter without changing capability or Agent/Gateway contracts.
❌ Historical decisions may be superseded. Use Architecture.md, Roadmap.md and the latest relevant ADR for current behavior.

✅ Output contracts distinguish ActionCall from native ToolCall; Function Token names the mixed text/XML protocol interpreted inside Agents.

✅ [0028](0028-inter-agent-communication.md) specifies the internal Agent communication design. ❌ Executable bus, runtime ports and communication configuration remain pending.

✅ [0029](0029-channel-lock.md) defines channel lock ownership, immediate takeover and the separation between Agent decisions and runtime authorization. ❌ Runtime enforcement remains pending.

✅ [Shared ModelManager](0030-shared-model-manager.md) defines unified registration and lifecycle ownership. ❌ Device stability and timed idle eviction remain pending.

✅ Model capability documentation covers the Qwen3.5 MLX production chat path and the shared management/resource contracts. Native CoreAI graph execution supports Nemotron ASR and diagnostic Kokoro TTS.

✅ [ModelKit project boundary](0033-modelkit-project-boundary.md) defines the root-package build, Management/Backends ownership, root test separation and automated boundary checks.

✅ [Internal default model assembly](0034-modelkit-default-assembly.md) defines ModelKit-owned registrations and capability defaults. App supplies resources and handles OS events.
