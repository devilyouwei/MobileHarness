# Third-party licenses

Purpose: preserve license notices for model artifacts and runtime dependencies. Design goals: retain the original legal text unchanged and distinguish current distribution from historical or comparison-only artifacts.

✅ Qwen35-Apache-2.0.txt accompanies the pinned Qwen3.5 model. MLX-Swift-MIT.txt and MLX-Swift-LM-MIT.txt preserve the runtime/library notices; these are retained for historical attribution and are no longer staged into app resources.
✅ Native CoreAI graph source notices remain for Nemotron and Kokoro, including CoreAIKit and CoreAIModels attribution.
❌ A license notice is not a model compatibility or quality guarantee. Development download profiles record model provenance.

✅ YOLOPose-AGPL-3.0.txt preserves the AGPL-3.0 license notice for the pose model lineage. The current App stages the notice alongside its pinned YOLO26 pose artifact; [ADR 0038](../adr/0038-yolo26-pose.md) records the model replacement. The license text itself is preserved unchanged.

✅ FluidAudio source dependency is pinned at 20d4f0bd46d11d7f50a6eb4f7835cfdbd2b4ba14; Apache-2.0 notice is staged. The model profile also includes ANE/ANE-zh model licenses. Mandarin G2P resources are supplied by the same pinned model repository; tokenizer vocabulary is separately pinned to google-bert/bert-base-chinese.

❌ Audio8 and ONNX Runtime are not current production adapters. Their notices remain here with the historical [Audio8 validation record](../validation/Audio8-Validation.md); retaining a notice does not imply that its model or SDK is packaged in today’s App.


✅ MOSS-TTS-Nano model notices are retained in MOSS-TTS-Nano-Apache-2.0.txt. Narrowly adapted FluidAudio source retains its Apache-2.0 attribution. ❌ No license claim is made for user-supplied voice recordings.

✅ Gemma4-Apache-2.0.txt and CoreAIModels-BSD-3-Clause.txt accompany the new Gemma/CoreAILM integration; current file lists stage these notices. ❌ Notices do not establish model quality/device acceptance.

✅ GRDB.swift7.11.1 is the Storage-owned SQLite adapter. [GRDB-MIT.txt](GRDB-MIT.txt) preserves its original MIT notice. GRDB uses Apple’s system SQLite; no database engine or dependency is exposed to UI/ModelKit/PlatformKit.
