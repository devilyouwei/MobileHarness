# Build configuration

Purpose: own shared Xcode settings, local-signing templates and explicit metadata resource inputs/outputs. Design goals: reproducible builds without local model weights, confined staging and private signing configuration.

- ✅ Shared Swift 6 / iOS 27 settings; local signing stays in ignored Local.xcconfig.
- ✅ Both device and simulator Voice-Models file lists stage only model-catalog.json and license notices. No model graphs, weights, tokenizers or voice assets are build inputs or packaged outputs.
- ✅ Regenerate lists with scripts/update-model-filelists.py after changing staging metadata/licenses. The pre-build cleanup removes obsolete Models output from incremental App builds; staging never removes developer source artifacts.
- ✅ Physical App requests com.apple.developer.kernel.increased-memory-limit. It is not a memory-availability guarantee; simulator does not request it.
- ✅ NSCameraUsageDescription covers local preview and pose inference. Camera denial does not block Settings/history or voice preparation.
- ❌ Signed-device performance, export compatibility and background transfer acceptance require separate validation; configuration/build success is not that evidence.

Weights are acquired in Settings through Management/ModelKitHub and installed in the sandbox. Separate Mac/comparison provisioning profiles are not App resource inputs. See [Management](../MobileHarness/ModelKit/Management/README.md#local-model-resources--current-contract).

✅ Local chat configuration now targets Gemma 4 E2B CoreAI; Qwen/MLX production bindings are removed. ❌ Real-model/device acceptance is separate from compilation and contract tests.

## Photo save and ignore — ADR0185

✅ NSPhotoLibraryAddUsageDescription requests only adding explicitly saved photos. Camera purpose text covers user-requested still capture and sending a requested observation to the configured model service. No Photos read permission or album enumeration is added.
