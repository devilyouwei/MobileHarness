# Build configuration

Purpose: own shared Xcode settings, local-signing templates and explicit metadata resource inputs/outputs. Design goals: reproducible builds without local model weights, confined staging and private signing configuration.

- ✅ Shared Swift 6 / iOS 27 settings; local signing stays in ignored Local.xcconfig.
- ✅ Both device and simulator Voice-Models file lists stage only model-catalog.json and license notices. No model graphs, weights, tokenizers or voice assets are build inputs or packaged outputs.
- ✅ Regenerate lists with scripts/update-model-filelists.py after changing staging metadata/licenses. The pre-build cleanup removes obsolete Models output from incremental App builds; staging never removes developer source artifacts.
- ✅ Physical App requests com.apple.developer.kernel.increased-memory-limit. It is not a memory-availability guarantee; simulator does not request it.
- ✅ NSCameraUsageDescription covers local preview and pose inference. Camera denial does not block Settings/history or voice preparation.
- ❌ Signed-device performance, export compatibility and background transfer acceptance require separate validation; configuration/build success is not that evidence.

Weights are acquired in Settings through Management/ModelKitHub and installed in the sandbox. Separate Mac/comparison provisioning profiles are not App resource inputs. See [Management](../MobileHarness/ModelKit/Support/Management/README.md#local-model-resources--current-contract).

✅ Local chat configuration now targets Gemma 4 E2B CoreAI; Qwen/MLX production bindings are removed. ❌ Real-model/device acceptance is separate from compilation and contract tests.

## Photo save and ignore — ADR0185

✅ NSPhotoLibraryAddUsageDescription requests only adding explicitly saved photos. Camera purpose text covers user-requested still capture and sending a requested observation to the configured model service. No Photos read permission or album enumeration is added.


✅ Navigation audit: Xcode file references/groups must mirror current Agents/Support and Resources/Agents/Skills locations. Remove retired Agent JSON navigation entries and add new metadata/control/state references. SwiftPM remains sole owner of these framework sources/assets; navigation changes do not duplicate target membership or resource phases.


## Skill 函数目录

✅ Xcode 导航删除七个 Permissions.json 引用，资源仍由既有 SwiftPM target 打包，无新增编译成员或签名配置。

## Action-owned documentation and Skill instruction contract

✅ Xcode 导航移除公共 FunctionMetadata 文件，登记 ActionDeclaration、TaskActions 和目录回归夹具。SPM 编译声明，FunctionContracts 不再打包具体函数 JSON 资源。

✅ Scheme pre-build cleanup removes the retired generated HarnessKit_FunctionContracts.bundle from incremental App output, so obsolete FunctionMetadata.json cannot survive a source migration. Source files are never cleaned.

✅ Implemented ProMotion packaging: Config/AppInfo.plist explicitly supplies CADisableMinimumFrameDurationOnPhone=true to both App targets. Generated standard/permission metadata remains enabled; remove the ineffective custom INFOPLIST_KEY setting and verify the final signed plist, not only build settings. No local signing edits.
