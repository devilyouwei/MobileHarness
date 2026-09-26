# ADR 0042 — ShowPose as a Completion-Only Tool

Status: accepted, 2026-09-26. Supersedes the Action path in ADR 0041; VisionPerception remains the owner.

✅ VisionPerception JSON declares UI.showPose as a tool. Each accepted pose yields one resolved ToolCall; no Channel and no per-frame Action completion control. Tools/UI validates the existing bounded overlay and awaits the injected MainActor presentation callback with trusted source/session context.

✅ ToolRegistry distinguishes data-returning String handlers from completion-only Void handlers. App registers UI.showPose using registerCompletion. Successful Void execution returns nil internally, creates no ToolResult and causes no InputGateway submission. Empty String remains a normal result. Callers cannot request feedback suppression via arguments. Handler failures and cancellation propagate; data-tool errors retain normal correlated feedback.

✅ There is no added Tool queue or detached task. The existing capacity-eight Agent output stream fails on overflow, and the App consumer awaits execution sequentially. The camera callback retains session/sequence rejection. This avoids Channel dispatch and result feedback, but makes no zero-overhead or immediate-main-thread claim.

❌ Latest-pending replacement for Tool outputs and physical-device latency measurements are outside this change.

Validation: root scripts/check.sh passed (82 IntegrationTests), all four simulator schemes passed, and the unsigned physical Release target built. The bundled VisionPerception JSON matches the Tool-only source declaration. No phone installation or device latency measurement was performed.
