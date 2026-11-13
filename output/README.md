# Generated evidence and design assets

Purpose: keep reviewable generated artifacts separate from production sources. Each evaluation directory documents its method and limitations.

✅ Image generation outputs and source prompts.
✅ [MobileHarness robot-brain concept](mobileharness-robot-brain.png) and its [source prompt](mobileharness-robot-brain-prompt.txt), generated with the built-in image tool. The iPhone coordinates an arm, rover, drone and quadruped through visual feedback streams; this illustrates the project vision, not verified hardware integrations.
✅ [MobileHarness laboratory banner](mobileharness-lab-banner.png) and its [source prompt](mobileharness-lab-banner-prompt.txt), edited with the built-in image tool. The 3:1 background simplifies the concept to an iPhone, arm, rover and drone in a futuristic indoor laboratory. Only the phone splash screen carries the app name; there is no external title or slogan. This remains conceptual artwork.
✅ [Laboratory banner v2](mobileharness-lab-banner-v2.png), the preserved edit source for v3. It features rich cyan-and-gold bidirectional streams, waveforms and pictorial telemetry, and a phone-controlled humanoid reaching to pick up the iPhone. All depicted robot integrations are conceptual.
✅ [Laboratory banner v3](mobileharness-lab-banner-v3.png) and its [source prompt](mobileharness-lab-banner-v3-prompt.txt), preserved as historical artwork and a layout reference for the office revision. Its central phone displays the earlier arm-and-phone logo.
✅ [Office banner v1](mobileharness-office-banner-v1.png) and its [source prompt](mobileharness-office-banner-v1-prompt.txt), edited with built-in ImageGen from laboratory v3 and the [enlarged blue wink](icon-concepts/mobile-eyes-wink-v4.png). The 2172×724 artwork depicts a sunlit office with a winking phone, four robots and blue and orange data paths.
✅ [Office banner v2](mobileharness-office-banner-v2.png) opens the [project README](../README.md). The 2172×724 concept illustration adds panels for drawing, document writing, web browsing and photography around the phone and robots.
✅ Qwen iPhone evaluation harness and pinned artifact hashes.
❌ Evaluation samples are not comprehensive quality benchmarks or production acceptance guarantees.

Do not store model weights, signing credentials, or user media here. Preserve historical reports rather than rewriting them after prompt or configuration changes.

✅ qwen35-mlx-2026-09-25 records MLX integration validation and distinguishes runnable inference from XML Action quality acceptance.

`webkit-acceptance-2026-11-03.jpg` / `.json` are iOS 27 simulator evidence from the standalone production-WebKit test host: authored local diagram fixture, JavaScript update/animation, remote HTTPS observation and snapshots. They are not LLM-generated acceptance or physical-device evidence; see [validation](../docs/validation/WebKit-Actions.md).
