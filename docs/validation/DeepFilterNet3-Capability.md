# DeepFilterNet3 capability validation

## Scope

Standalone ModelKit enhancement, not listening integration or physical-device acoustic acceptance. Core ML export: aufklarer/DeepFilterNet3-CoreML revision `937bad9811f1ffc1a06ea0d676461b080b2bdc93`; model/auxiliary downloaded to `/tmp/DeepFilterNet3`, outside git. CPU-only inference selected explicitly. DSP reference: soniqo/speech-swift revision `b1287a6c963a38b0d4133c656725b2de7ea6bebf`.

## Reproduction

- `DEEPFILTER_MODEL_ROOT=/tmp/DeepFilterNet3 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter deepFilter`
- `./scripts/check.sh`
- `./scripts/build-ios.sh`

The real-model test is explicitly disabled without `DEEPFILTER_MODEL_ROOT`. It checks short/non-hop-aligned/max-size silence, finite PCM, output count/timing, deterministic state reset and changed noise output. DSP roundtrip checks delay/scale independently from the network. Auxiliary tests check Fortran layout, malformed/truncated archive rejection and the real filterbank's frequency coverage. Input tests reject wrong format/nonfinite PCM before loading; default assembly test verifies optional lazy registration and explicit missing-model failure.

## Results

- Final focused run: six tests passed (five DSP/provider tests including actual Core ML inference, plus default registration). Real-model case completed in 1.597 seconds on this Mac; this aggregate smoke-test duration is not a streaming latency benchmark. Log: `/tmp/deepfilter-final-tests.log`.
- `./scripts/build-ios.sh`: all five schemes passed for final source: MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron, ModelKitSilero, ModelKitAppleLLM. Log: `/tmp/deepfilter-final-ios.log`. This is simulator compilation, not iPhone installation or acoustic acceptance.
- `./scripts/check.sh`: architecture checks, eight Python tests and strict Swift formatting passed. Enhancement tests passed (real model deliberately disabled without its environment variable). Full Swift suite was not green: Decision route assertion, robot action expiration and NexArm target assertion failed; Writer/Web reported missing injected Action declarations. AppWorkflow then made no log progress for 94 seconds; only this check process tree was terminated. The script's subsequent native-runtime phase and plist phase were not reached. Log: `/tmp/deepfilter-check.log`.
- `git diff --check` passed; new README relative links verified.

Initial compilation diagnostics and the first real-model test exposed the exported `[1,96]` normalization-state shape. The corrected shape and minimum-three-frame padding are included in the final successful model test. No weights, downloaded media or signing configuration were added by this feature.

## Limits

Synthetic model smoke tests do not establish speech quality, SNR improvement, echo suppression, iPhone speed or AirPods behavior. The published graph has no external recurrent-state tensors; each call resets internal recurrent state. The interface is bounded batch processing and makes no continuous streaming guarantee. It is not automatically loaded or inserted into current listening.
