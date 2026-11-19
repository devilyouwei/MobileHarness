# D3 iOS AOT validation — 2026-11-15

## Scope and environment

Mac17,5 / Apple A18 Pro, Xcode 27.2 (27B52), Metal Toolchain 27B47. The AOT target is iOS 27.0, architecture h18p, default compute placement. The Mac's own runtime architecture reports h17p; compiled h18p assets must be accepted on the target phone, not treated as Mac inference evidence.

Source graphs and per-file build inventories are recorded in [the measurement](../../experiments/decision/results/decision-d3-ios-aot-2026-11-15.json). Edge source revision is 0690c04ee1640c1c3fa11a882323751dda6d086a; Lite is 863963d371d5af6784bf726fb85a508c08751d65. Tokenizers, prompts, graph inputs and scoring policy are unchanged. iOS manifests add compiled_models for native architecture selection.

## Compilation

Both commands completed with exit code 0 and produced complete decision.h18p.aimodelc bundles:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun coreai-build compile \
  Models/D3Lite/decision.aimodel \
  --platform iOS --min-deployment-version 27.0 --architecture h18p \
  --output Models/D3Lite/decision-ios
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

Sanitized evidence: [Lite AOT crash measurement](../../experiments/decision/results/decision-d3-lite-ios-aot-crash-2026-11-15.json). Raw reports and copied device files remain under /tmp and are not committed. This investigation did not implement a crash fix; the AirPods startup investigation is also still unresolved.

## Edge source-package selection restored — 2026-11-17

At the user's request, Edge no longer selects the h18p AOT override. All architectures use hugging-mac/d3-edge-CoreAI revision 0690c04ee1640c1c3fa11a882323751dda6d086a and decision.aimodel plus its matching manifest/tokenizer/configuration. Lite's AOT selection and generic architecture support are unchanged. This isolates the package selection change; the minimal production prompt and adoption rules are unchanged.

The fixed HF API revision was fetched successfully after two incomplete HTTP responses. All 12 corresponding local Mac artifact files match remote content: LFS SHA-256 for large files and Git blob SHA-1 for ordinary files, with local SHA-256 also recorded. See [file parity evidence](../../experiments/decision/results/decision-edge-source-rollback-parity-2026-11-17.json). This verifies the selected source package against Mac artifacts, not iPhone inference parity. Existing AOT receipts do not match the source revision; the phone must remove and download Edge through Agent Models. Installing an App catalog alone does not replace installed weights or receipts.

Historical prompt evidence: the official-format utterance-status variant scored 113/182 (62.1%) on development and 29/48 (60.4%) on held-out synthetic cases; the latter was reproduced with all 48 predictions unchanged. The later changed discard definition scored 13/48, and the subsequent minimal template scored 1/6 on a small diagnostic set. These are Mac source-graph results; they already establish prompt-dependent errors without iOS AOT. No numerical AOT defect is established by this configuration rollback.

The production catalog regression passed: h18p Edge and Mac share the exact pinned source revision, Edge has no compiled-file requirement, and Lite retains its compiled variant. `check.sh` passed boundaries, eight Python tests and strict Swift formatting; IntegrationTests reported 11 issues across 1204 tests, followed by AppWorkflow missing Action declaration failures and stalled progress. The check and its child processes were stopped; subsequent native/plist stages did not run. Full check did not pass.

The first build-ios and signed-device attempts stalled before package resolution. A one-second sample of this task's xcodebuild showed IDEContainer opening the project blocked in NSFileCoordinator / semaphore_wait_trap. Both task-owned builds were stopped and the device build retried serially; no unrelated process or system coordinator was terminated. These attempts cannot be counted as successful builds.

Serial device retry remained blocked at the same pre-resolution point for over 80 seconds and was stopped. No new App was installed and no device model files/receipts were changed. Build logs: `/tmp/d3-edge-source-ios.log`, `/tmp/d3-edge-source-device-build.log`, `/tmp/d3-edge-source-device-retry.log`; sample: `/tmp/d3-edge-source-build-sample.txt`. Diff formatting passed.

## Source-catalog App installed — 2026-11-17

After the user saved and exited Xcode, the blocked project read resumed. Signed Debug iPhoneOS build completed successfully (`/tmp/d3-source-install-build-retry.log`). Strict deep signature, 73 Agent/Skill assets, Live Activity and English/Simplified Chinese resources passed validation. The packaged catalog is byte-identical to current source, pins Edge source revision 0690c04ee1640c1c3fa11a882323751dda6d086a and contains no Edge architecture override.

Installed dev.mobileharness.app in place on Youwei’s iPhone 17 Pro, receipt sequence 7228 (`/tmp/d3-source-install-device.log`). No uninstall or data clearing occurred. Launch was denied because the phone was locked (`/tmp/d3-source-install-launch.log`); installation succeeded, launch and inference acceptance did not. The user still needs to remove the existing Edge model and download the source package in Agent Models; no installed model file or receipt was manually replaced.

## Alternative publisher configuration — 2026-11-17

User requested an independent publisher for physical-device comparison. Edge now pins maxffarrell/d3-edge-CoreAI revision ffa8431fe8dd5209f3ec2c8bf59afc829ec96c31. Only the decision graph and text companions are selected; estimated size is 1,013,190,012 bytes. No vision graph or external Python code is installed into the App. Model ID/directory, prompts, adoption rules, Lite and historical Mac artifacts remain unchanged.

Remote manifest, decision configuration, tokenizer, tokenizer configuration and chat template hashes were verified. The existing D3 adapter supports the five inputs and supplies zero visual embeddings plus a false visual mask for text. The graph retains 512 tokens and 255 answer codes. Metadata evidence: [alternative artifact](../../experiments/decision/results/decision-alternative-edge-artifact-2026-11-17.json). This is contract compatibility, not a successful native load or classification test of this artifact.

The publisher documents numerical drift and no iPhone acceptance. Its upstream revision 18d61df78684675463af9ae732872478845c5a79 differs from the hugging-mac package's bee5e872f75b9c5d1405767bf244a6948b95c0af. This comparison changes publisher/export and upstream revision; it is not a strictly identical-weight compiler isolation experiment. The original Hello request also reproduced discard on Mac three times before this source change.

Existing hugging-mac installation receipts mismatch the new publisher/revision. After installing the App, remove and re-download Edge through Agent Models. App installation alone does not replace model files.

The alternative source catalog regression passed. All five iOS build schemes and the signed physical-device build passed. Strict deep signature, Agent/Skill, Live Activity and bilingual resources passed; packaged catalog is byte-identical to source and pins maxffarrell without an architecture override. Installed in place on iPhone 17 Pro with receipt sequence7236 and successfully launched. Logs `/tmp/d3-alternative-{device-build,install,launch}.log`. Existing model data was retained; the user must explicitly replace Edge through Agent Models before testing the third-party artifact. No successful third-party inference is claimed by installation.

Full check passed boundaries, eight Python tests and Swift formatting, but reported IntegrationTests issues and AppWorkflow missing Action declarations/model-list expectations. The task-owned check processes were stopped after these failures were confirmed; subsequent native/plist phases did not run. Full check is not a pass. No unrelated test code was changed. Diff formatting passed; `/tmp/d3-alternative-check.log` preserves the failures.

## Own source restored after third-party test — 2026-11-17

At the user's request, Edge source and requiredFiles were restored exactly from experiments/decision/benchmark/models.json: hugging-mac/d3-edge-CoreAI revision0690c04ee1640c1c3fa11a882323751dda6d086a, original decision.aimodel, no AOT override. The production catalog regression passed. The signed device build, strict deep signature and Agent/Skill/Live Activity/localization validation passed; packaged catalog matches source byte-for-byte. Installed in place with receipt sequence7244. Launch was denied because the iPhone was locked. Logs `/tmp/d3-restore-own-{device,install,launch}.log`. Existing third-party model files were not altered; Agent Models removal/download is required to acquire the restored source. Prompt candidates were evaluated offline only, with no production prompt or adoption changes.

All five build-ios schemes passed. check.sh passed boundaries, eight Python tests and formatting, then reported Integration/AppWorkflow failures including missing injected Action declarations. The check and task-owned children were stopped after confirming failures; subsequent native/plist phases were not run. Full check is not a pass. Diff formatting passed. No unrelated behavior was modified for test success.
