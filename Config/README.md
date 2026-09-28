# Build configuration

Purpose: own shared Xcode settings, local-signing templates and explicit model resource inputs/outputs.

✅ Shared Swift 6 / iOS 27 settings; local signing stays in ignored Local.xcconfig.
✅ Physical-device resource lists include Qwen3.5 MLX 2B weights, tokenizer and licenses alongside Nemotron, Silero and standalone Kokoro assets.
✅ The generated Models output directory permits cleanup before staging the selected model directories; source model artifacts are never removed.
❌ Configuration alone does not establish device performance or compatibility; these require signed-device validation.

✅ MobileHarness.entitlements requests com.apple.developer.kernel.increased-memory-limit on the physical app target, matching the official MLX LLMBasic example. It is not a guarantee of memory availability, and the simulator target does not request it.

✅ Run python3 scripts/update-model-filelists.py after editing production download profiles. It generates explicit Xcode sandbox file inputs and outputs; staging copies only those required files and licenses.

✅ Shared.xcconfig includes NSCameraUsageDescription for local preview and on-device pose inference. The camera is optional; denial leaves the background black and does not block voice model preparation.

✅ Device resource file lists now stage the pinned YOLOPose mlpackage and upstream model card. Camera permission text describes local pose inference; no uploads or recording.

✅ Physical model file lists now stage yolo26n-pose.mlpackage only. The generated App Models cleanup and declared-file copy prevent the retired YOLOv8 package from shipping.

✅ Voice model file lists now stage KokoroCoreML Mandarin/English graphs, local pronunciation resources and FluidAudio license. Regenerate with scripts/update-model-filelists.py.


✅ Voice model file lists now stage only the four MOSS streaming graphs, preset voice codes and supporting metadata for TTS. Kokoro resources are excluded. ❌ Physical-device acceptance remains pending.
