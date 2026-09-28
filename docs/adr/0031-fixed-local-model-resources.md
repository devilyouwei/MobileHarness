# ADR 0031: Fixed local model resources

> Historical scope: Fixed-provider snapshot. Later decisions changed default synthesis to bilingual Kokoro and added explicit cloud chat selection; see [ADR 0052](0052-kokoro-coreml-bilingual.md) and [ADR 0053](0053-settings-live-chat.md).

Status: accepted.

App selects one fixed model per capability: Nemotron for ASR, Qwen3.5-2B for chat, Silero for VAD and Apple system TTS. Kokoro remains an explicit diagnostic provider. The shared ModelManager owns registration, instance identity and load/unload; capability consumers do not inspect resource configuration.

Model adapters accept a local model directory. Backend SDKs validate required formats and compatibility while loading. The application has no runtime artifact manifest, per-file checksum catalog or version-hash directory. Required native model metadata stays intact.

Development download JSON contains source, fixed revision, destination and required file paths. Flat directories keep deployment simple; changing revisions requires a forced refresh of existing files. Four download workers use temporary files and atomic replacement. No runtime network loading or automatic variant fallback is provided.

Audio8 and Qwen4B download profiles remain for reproducible comparison. Their weights are excluded from the working resource set and App. Audio8's adapter and ONNX dependency are absent; reintegration needs an explicit dependency decision. Simulator ASR and chat report unavailable.

✅ Resource loading, registration and staging implement this contract.
❌ Corruption detection before backend loading, in-app model installation and physical-device memory acceptance are not provided by this design.

## Validation

- ✅ scripts/check.sh: formatting, root tests and project metadata validation.
- ✅ Optional ModelKit package tests; real Mac Qwen2B generation, cancellation, unload/reload and tokenizer fixture parity.
- ✅ Real Mac Nemotron English/Chinese packet-parity and cancellation tests; Silero reset/tail/packet tests; Kokoro repeated synthesis.
- ✅ Four simulator schemes and the signed physical MobileHarness build.
- ✅ Packaged files match required local file sizes, contain no application artifact manifests, Audio8 or ONNX, and use only Nemotron/Qwen35/Silero/Kokoro/Licenses directories. Debug App is 3,493,456,591 uncompressed bytes (about 3.3 GiB).
- ❌ This build has not been installed or acceptance-tested on the iPhone. Mac inference and successful signing do not establish physical-device retry stability.
