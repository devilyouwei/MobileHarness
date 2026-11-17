# DeepFilterNet3 listening integration validation

Date: 2026-11-16. Host: arm64 macOS, full Xcode Swift 6.4.2. This report covers application integration; standalone capability evidence remains in [DeepFilterNet3-Capability](DeepFilterNet3-Capability.md).

## Implemented behavior

Installed DeepFilterNet3 is an optional foreground preload step, independent of the persisted listening toggle. Absent artifacts skip preparation; installed-model failures propagate. Speech Recognition manages download/progress/cancel/delete and an independent noise-suppression toggle (default off, applies at next listening start). Enabling requires installation; restoring after model removal disables the toggle.

Native VPIO/AEC capture → mono/W → 48 kHz conversion → optional windowed DeepFilterNet3 → 16 kHz conversion → shared VAD/ASR. Full-duplex input remains open during assistant speech. Ordinary ASR endpoints retain preprocessing history. The exported model is processed using overlapping independent windows, not persistent recurrent streaming; first output requires 400 ms of captured audio.

## Automated and real-model evidence

- Thirteen focused test functions passed in `/tmp/enhancement-bulk-tests.log`: two Core ML dense/strided transfer tests; six window/PCM tests; optional startup skip; three workflow/preference tests; settings toggle persistence/rollback. Parameterized enabled/disabled workflow paths both passed.
- Coverage includes exact sample count/timestamps, overlap gain, short-tail flush, invalid/gapped input, inference failure and reset, in-flight invalidation, installation requirement, legacy preference defaults, removal/restore, and both VAD/ASR consuming the same denoised signal. ASR endpoint regression verifies that later windows retain full capture history.
- Earlier focused voice regression run passed full-duplex/half-duplex continuation, native-rate conversion, recovery and cold VAD/ASR behavior (`/tmp/enhancement-business-final-tests.log`). These are injected-capability tests, not physical microphone acceptance.
- Real model loaded from `/tmp/DeepFilterNet3` (catalog-pinned artifact). Final windowed smoke test: preload 0.305 s; 2 s / 96,000 samples processed in 0.655 s with CPU execution, including PCM DSP and tensor transfer. A preceding preloaded run took 1.785 s before dense tensor transfer optimization. Single-run host measurements under differing concurrent load are diagnostic, not a controlled benchmark or iPhone throughput guarantee. Exact output count and finite PCM were checked; no speech quality metric was measured.

## Full project checks

`./scripts/check.sh` was executed. Architecture/catalog/dependency checks, eight Python tests and strict Swift formatting passed before the Swift suite. The broad suite recorded failures including Decision routing expectations, NexArm tracking, expired robot/Bluetooth actions and Writer/Web missing injected Action declarations. It then stopped making progress in AppWorkflowTests; its owned processes were terminated after more than two minutes in that test process. This is **not a passing full check**. Log: `/tmp/enhancement-business-final-check.log`.

Final strict Swift format lint passed with no diagnostics; project/plist/entitlements validation and `git diff --check` passed. `./scripts/build-ios.sh` completed successfully for all five schemes after the tensor optimization (`/tmp/enhancement-bulk-ios.log`): MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron, ModelKitSilero and ModelKitAppleLLM. These are simulator builds, not an installation on iPhone.

The separately invoked `swift test --filter 'LiveRuntimeTests|NativePresentationTests'` phase executed 228 tests and reported one failure: `soundSourceReplyGateClearsDirectionAndResumeStartsANewWindow` timed out. Its synthetic VAD emits three positive windows, incompatible with the previously introduced eight-window default. The test now explicitly injects `(3, 0.65)` to exercise its original reply/direction lifecycle. Production defaults and all direction assertions are unchanged. The corrected test passed in isolation (`/tmp/enhancement-sound-final.log`); the full 228-test phase was not repeated after this test-only correction. Final test-file format lint and diff checks passed. The broad suite remains non-green for the failures above.

## Remaining acceptance

No physical-device installation, AirPods/phone acoustic validation, native settings-page interaction, sustained iPhone latency/thermal measurement or noise/assistant-echo quality acceptance was performed in this integration turn. DeepFilterNet3 is noise suppression with no playback reference; it does not replace native echo cancellation or guarantee removal of assistant speech. Verify both routes with the model enabled and disabled, insertion during replies, start/stop, model deletion and rapid route changes.

## Physical-device delivery — 2026-11-16

At the user's request, built the current MobileHarness Debug app for the connected iPhone 17 Pro using existing team signing through a command-line override. Device build succeeded (`/tmp/deepfilter-device-build.log`). Agent/Skill resources (73 assets), embedded Live Activity and English/Simplified Chinese resources passed verification; the initial sandboxed Agent resource check failed on compiler-cache access and passed when rerun with that access. `devicectl` confirmed installation and launch of `dev.mobileharness.app`. No uninstall or app-data reset was performed. This delivery supersedes the earlier no-install scope statement only; model download, acoustic quality, full-duplex insertion and sustained device performance remain unverified.
