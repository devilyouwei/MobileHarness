# D3 iOS AOT validation — 2026-11-15

## Scope and environment

Mac17,5 / Apple A18 Pro, Xcode 27.2 (27B52), Metal Toolchain 27B47. The AOT target is iOS 27.0, architecture h18p, default compute placement. The Mac's own runtime architecture reports h17p; compiled h18p assets must be accepted on the target phone, not treated as Mac inference evidence.

Source graphs and per-file build inventories are recorded in [the measurement](../measurements/decision-d3-ios-aot-2026-11-15.json). Edge source revision is 0690c04ee1640c1c3fa11a882323751dda6d086a; Lite is 863963d371d5af6784bf726fb85a508c08751d65. Tokenizers, prompts, graph inputs and scoring policy are unchanged. iOS manifests add compiled_models for native architecture selection.

## Compilation

Both commands completed with exit code 0 and produced complete decision.h18p.aimodelc bundles:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun coreai-build compile \
  Tests/DecisionBenchmarks/.local/models/D3Lite/decision.aimodel \
  --platform iOS --min-deployment-version 27.0 --architecture h18p \
  --output Tests/DecisionBenchmarks/.local/models/D3Lite/decision-ios
```

Edge uses the corresponding D3Edge paths. Both processes emitted `Failed to import MPS module` before successful compilation; this message was not an exit failure. The resulting package contains MPSGraph executable resources. Compilation completion is not proof that the phone performs no additional specialization or that model numerics match the source graph.

## Publication and application integration

Publication targets existing hugging-mac/d3-edge-CoreAI and hugging-mac/d3-lite-CoreAI repositories under ios/aot-v1/h18p. Initial upload failed with 403 before any commit because the active fine-grained token covered the personal namespace only. After the user added organization scope, both repository write checks passed and uploads began. Remote file sizes and SHA-256 (LFS) / Git blob hashes were subsequently verified for every published file: Edge 18 files at 61a6a13a44d8390a5cf72755a6f581238ca88740; Lite 19 files at 4aff26452f53609516813ea61ee76b431b49a4e9. The catalog pins those commits in h18p variants.

ModelKit resolves architectureVariants before acquisition; the selected source revision, required files and estimated size are consistent across download and receipts. Other architectures retain their original source packages. D3 compiled manifests reject a nonmatching native architecture; no on-load silent source fallback is introduced.

## Checks

- ModelKit boundary checks and 8 Python download tests passed.
- ModelKitRuntimeTests: 48 tests passed, including exact architecture resolution, source retention and invalid unselected variant rejection.
- scripts/build-ios.sh: all five targets passed.
- Physical-device App build passed with the existing development team supplied as a command argument. The first attempt lacked a team for Live Activity; project signing settings were not edited.
- scripts/check.sh was run, but is not a clean pass: the first IntegrationTests run reported 3 issues in two time-sensitive tests (InputDecision possible-speech local route/model result and NexArm newest pending target). AppWorkflowTests reported missing injected Action declarations in Writer/Web cases and capture timeout assertions. The Writer cancellation/backoff test remained running for over five minutes; a sample was saved under /tmp and that helper was terminated. The subsequent native phase passed 228 tests. An isolated rerun passed all 48 ModelKitRuntime tests and both initially failing timing tests. The full check remains a failure because AppWorkflowTests did not complete cleanly.

## Outstanding acceptance

Physical-device cold-load/inference parity must be recorded before claiming the original Lite loading issue is fixed. Old source-model installation receipts do not match the new AOT revision; the application requires explicit removal and download of the updated package.

## Final catalog regression

After pinning both verified HF commits, 49 ModelKitRuntime tests passed, including loading the real production catalog and checking compiled-only h18p file selection, pinned revisions, tokenizer/manifest/large-resource inclusion and source retention. Both isolated Integration timing tests passed again. Eight Python download tests, changed Swift-file format lint and git diff --check passed. The final signed physical-device App build passed. Its packaged model catalog is byte-identical to the updated source; 73 Agent/Skill assets, Live Activity and English/Simplified Chinese resources were verified. devicectl successfully installed dev.mobileharness.app on the connected iPhone 17 Pro. No compiled-model cold load or inference was run on the phone in this publication task.

## Lite physical-device failure — 2026-11-15 23:42

The user reports Edge AOT loads normally and Lite repeatedly terminates the App. Two device reports (23:42:13 and 23:42:52, iOS 27.0.1 / 24A446) show identical EXC_BAD_ACCESS/SIGSEGV at address 0x3f5 in `MPSGraphAICodeCompilerDelegate getInitializedAICodeBytecodeWithPayloadPrefix:delegateId:`. The companion compiler thread includes GraphModel.init → D3Graph.init → ModelResource.ensureLoaded. These incidents report signal termination, not a jetsam memory-limit kill; this does not by itself exclude all allocation-related compiler defects.

Read-only extraction confirms the installed receipt is revision 4aff26452f53609516813ea61ee76b431b49a4e9. All 19 installed files were copied and SHA-256 compared with the locally built, remotely verified package. Every file matches, including the 2,503,298,936-byte resources.bin (96b4d664b6aa76e5d3a72aead6f18090d3e00bc3fe5b1ea3703810241002f070). Re-downloading the identical revision is not a content-integrity remedy.

Mac SDK inspection of SpecializationOptions.default reports expectFrequentReshapes=false, preferredComputeUnit=nil, matching the current default-option path. This is not a device measurement of runtime options. A first-party experiment report describes the same crash symbol with other triggering configurations ([report](https://john-rocky.github.io/coreai-model-zoo/knowledge/coreai-error-index.html)); matching a symbol does not prove the same cause. There is no evidence yet that a file-size boundary, a particular Lite operator, a compiler version mismatch or cache state is the specific trigger here.

The current Lite AOT package fails physical-device acceptance. Edge success is user-reported rather than independently measured here. No App code, installed model, cache, selected model, HF package or device OS was changed during this investigation. Use Edge while isolating the failing Lite graph; source-model rollback would restore the previously observed long specialization and is not presented as a fix. Any replacement export/compute preference must pass actual device load and inference parity before publication.

Sanitized evidence: [Lite AOT crash measurement](../measurements/decision-d3-lite-ios-aot-crash-2026-11-15.json). Raw reports and copied device files remain under /tmp and are not committed. This investigation did not implement a crash fix; the AirPods startup investigation is also still unresolved.
