# Reusable UI Components

✅ RetainedFullScreenCover.swift 提供保持下层视图挂载的全屏覆盖接口。UIViewControllerRepresentable 锚点只持有一个 UIHostingController，采用公开 [UIKit overFullScreen](https://developer.apple.com/documentation/uikit/uimodalpresentationstyle/overfullscreen) 保留下层视图树；一个 transition 标记与最新 binding 合并开关，呈现/关闭完成后再协调，无队列。源销毁不重新呈现，等待实际关闭后回调一次；内容更新不重建已呈现控制器。它只拥有页面呈现，不拥有业务/设备生命周期。

## Summary

State-driven eye geometry, numeric spectrum bars and streaming captions.

## Ownership and boundaries

SwiftUI presentation with native Core Animation/Metal rendering. Components consume UI values and emit renderer acknowledgment; they own no inference/device/scheduling services.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Pages[Conversation and camera] -->|expression, gaze, phase, numeric bands| Eyes[CompanionEyes and VoiceBars]
 Pages -->|full caption text and color| Caption[FadingCaption]
 Eyes -->|request-scoped completion and availability| Host[Injected presentation callback]
```

## Eyes and completion

Both eyes preserve shape identity/path topology across clear, smile, happy, laugh, thinking, surprised, sad, love, angry, scared and playful states. Each eye is 21% of face width, gap 19%, height 25%. EyePose supplies smile/slant/heart/opening/width/rotation/color/offset values; native layers interpolate matched paths and transforms without swapping images or emoji.

Normal expression changes use a 0.65-second eased layer transition. Waking from closed uses a 180 ms cubic ease-out (0.16, 1, 0.3, 1); closure uses 460 ms ease-in-out. A native animation delegate acknowledges the request ID and whether its duration completed; replaced or unavailable requests do not fabricate success. One-shot emphasis adds 6% then returns, including when the emotion matches the persistent base. Gaze uses horizontal 14%/vertical 9% face-width offsets and a 0.32-second eased transition. Blink/breath are independent layer animations, delayed 1.2 seconds after waking and removed when inactive, reduced motion or resting closed. Disappearance/inactivity reports unavailable so the host can cancel a wait. Reduce Motion uses a 0.2-second acknowledgment transaction and suppresses repetitive motion.

## Spectrum and captions

`VoiceBars` draws 32 supplied bands, without FFT or audio generation. Production metering and synthetic preview values remain distinct. Geometry uses public safe-area values, without modifying system island UI. Decorative drawing ignores touch and VoiceOver.

✅ FadingCaption 将完整当前值同步交给原生 caption surface，不保存异步 SwiftUI 文本副本。CaptionPresentation 保留最多 320 个完整 Characters，输出稳定前缀的 UTF-16 边界；定稿/Reduce Motion 直接显示全值。两个 UILabel 使用相同完整字符串、字体、段落和排版，仅颜色范围不同；新增范围通过 CABasicAnimation.opacity 在 250 ms 内淡入。模型层透明度始终为 1，取消、替换、离窗或移动不会使文字停在低透明度。UIScrollView 仅在内容/布局变化时定位尾部，不随每段文字启动另一条滚动动画；没有逐字 timer、逐帧 SwiftUI body 或后台任务。18 pt 边缘留白/渐变和完整文本辅助功能保留。真实设备帧率需要测量，不由 API 选择推断。采用 Apple [Core Animation 图层动画](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CreatingBasicAnimations/CreatingBasicAnimations.html)；模型层保存可读终值，呈现层仅负责过渡。

Parameterized expressions, request-scoped animation completion, numeric bars and bounded caption rendering.

## Related design

[Parent design](../README.md)

## Native companion rendering

`EyeGeometry.swift` supplies eight clockwise cubic segments with shared anchors and equal incoming/outgoing tangent handles. Smile/slant and closed-eye deformations apply the same derivative to their handles; slant lowers the selected brow within the eye bounds. Love uses corresponding top/lobe/side/bottom anchors and a softly rounded notch/tip. Linear path interpolation preserves continuous derivatives at every join, avoiding the former side reversal and protruding curves. The geometry remains portable and topology is identical across all expressions. `NativeCompanionSurface.swift` owns a stable UIView, CAShapeLayer eyes and a CAMetalLayer rim. Explicit path/shadowPath/transform interpolation starts from presentation values on interruption. Shadows have explicit bounded eye paths; no full-screen blur or per-frame SwiftUI eye body is used. `CompanionEyes` is only the startup/standalone wrapper for this same implementation.

`ListeningMotion.swift` uses a monotonic epoch and actual listening generation. One native update supplies the same timestamp to both eye animations and halo state; every new generation replays the front even if SwiftUI coalesces off/on. The cached bundled Metal pipeline is prepared off MainActor before a coordinated wake commits. Pipeline/GPU failures reach an injected display callback; eyes still retain genuine animation acknowledgment when the halo is unavailable.

`ListeningHalo.metal` draws one premultiplied fullscreen triangle pass. A soft point-source flash, circular radial front and filled luminous tail expand from the generation-latched contact point and converge into the rim over 720 ms, settles by 1.05 seconds, and combines cyan/blue/violet/pink/amber fields with local highlights. A 320 ms entry starts at at least 0.85 visibility and rises to 1; the 320 ms smoothstep exit preserves current opacity during reversal; there is no duplicate SwiftUI fade. Reduce Motion uses a static field and 200 ms fade.

`MetalHaloRenderer.swift` owns a user-interactive run-loop thread and CAMetalDisplayLink, sampling targetPresentationTimestamp. UIKit passes only a latest immutable state snapshot through Mutex. Wake notifications coalesce to one pending slot; at most three GPU commands are in flight. A full frame budget drops only that display frame instead of queueing. Transitions request the attached screen's supported refresh rate; settled flow requests 60 Hz. Idle/reduced settled/inactive rendering pauses after the needed frame. Disposal is idempotent, invalidates on the render thread and joins GPU completions off MainActor before stopping its loop. Frame callbacks use an autorelease pool, and the terminated owner releases its Thread reference. Views own no microphone, camera or model lifetime.

finite eye-layer transitions explicitly request the attached screen's supported CAAnimation preferredFrameRateRange, matching the Metal transition request. Actual ProMotion refresh remains system-controlled.

ListeningLightOrigin validates finite normalized coordinates; ListeningMotion latches the origin on a new generation. NativeCompanionSurface maps the local content point, including safe-area offsets, into a SIMD2 uniform in the full-window Metal layer; per-pixel radial distance drives edge arrival.

The host-facing origin value is `ListeningLightOrigin(x:y:)`, with coordinates in 0…1 relative to home content bounds (top-left origin). Nonfinite values use the eye-center default per axis; out-of-range finite values clamp. `ConversationState.listeningLightOrigin = nil` uses the current eye center. UIKit converts content coordinates into the full-window layer before the activation latches them; only a fresh generation starts a new wave. Steady-state updates do not relocate a running/fading wave.

normal entry visibility starts at at least 0.85. A native discrete z-position animation places the existing Metal flash above eyes only during the 0.9 s activation pulse, then restores the original settled/exit stacking. Reduce Motion retains its static field. Exit opacity duration/easing remain unchanged.

UI.Notice.showNotice/dismissNotice and UI.Light.updateLight are canonical presentation Actions for trusted business calls, currently registered by no Skill. Neutral Actions values cross RuntimePresentation into root-owned HomeEffectsWorkflow, which retains one replaceable notice expiry and one light expiry, UUID-fenced cleanup, and explicit stop. Notices remain separate from factual ExecutionIssue history; actual upper-layer errors have display priority and Action failures remain panel-only. Decorative light accepts normalized origin, initial opacity/intensity and duration; it never changes consent, microphone or eyes. Native renderer separates light generations from listening eye generations and preserves existing exit fade. RuntimePresentation converts neutral Action requests into UI-owned values; HomeEffectsWorkflow now belongs to UI with no project dependencies. UI remains a presentation-only consumer of injected values.

UIModule.effectDefinitions exposes the same canonical factories for isolated hosts, with nil capability explicitly unavailable. Isolated effect tests provide explicit capabilities. Clearing a decorative override restores an already-active listening rim without replaying its wake burst; its new generation still replays normally.

## 待实现

- Multistage performance queues and gesture-driven gaze.

- Requested refresh is not guaranteed FPS. Synthetic device traces and live camera/ASR/model acceptance are distinct; see [validation history](../../../docs/validation/Validation-History.md).
