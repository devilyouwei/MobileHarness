# User and Model Configuration Guide

This guide covers device setup, model configuration, download sources, and interaction controls for MobileHarness. For overall architecture and module design, see [Technical Design](../MobileHarness/README.md) and [Product Scope](Product-Scope.md).

## Build Variants and Signing

- **Physical device (`MobileHarness` scheme):** Full local-inference configuration for iOS 27+ devices.
- **Simulator (`MobileHarnessSimulator` scheme):** `./scripts/build-ios.sh` selects this scheme and sets `MOBILEHARNESS_BUILD_VARIANT=simulator` during package resolution to exclude the device-only Gemma backend. Local Gemma chat is unavailable in this variant; conversation requires an explicitly configured cloud provider. See [Gemma4](../MobileHarness/ModelKit/Language/LLM/Gemma4/README.md) for the platform boundary.
- **Device signing:** Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` in that ignored local file. Builds bundle the pinned model catalog and notices, not inference weights; no model download is required before building.

## Model Configuration

Open **Settings → AI Models** to manage **Speech**, **Vision**, and **Agents**.

- **Local text conversation:** Download a compatible **Gemma 4 E2B** artifact. The current local Gemma iOS graph supports only hardware identifiers `iPhone18,1` and `iPhone18,2`; other devices require an explicitly configured cloud chat provider. See [Gemma compatibility](../MobileHarness/ModelKit/Language/LLM/Gemma4/README.md#local-gemma-engine).
- **Cloud chat:** Explicitly configure a provider implementing the **Responses API** (a provider offering only Chat Completions is insufficient). Photo understanding requires an image-capable cloud model; local Gemma does not support images or native Tools. Cloud chat replaces chat only.
- **Speech:** The menus select voice activity detection, end-of-turn confirmation, noise suppression, keyword spotting, speech recognition, and speech synthesis. Energy detection and Apple speech are the defaults. End-of-turn confirmation, noise suppression, and keyword spotting start off. Download Silero, Smart Turn, DeepFilterNet3, Zipformer, Nemotron, MOSS TTS Nano, or Kokoro 82M in the matching section before selecting it. After choosing Kokoro, switch between English and Mandarin Chinese in Voice language and pick a Voice from that language’s list.
- **Decision (Full-duplex):** Configure a local or cloud Decision model under **Agents → Decision** to classify interruptions and quiet-mode wake requests.
- **End-of-turn confirmation:** Download and select Smart Turn v3.2 in Speech. It checks whether you have finished speaking when voice activity detection finds a pause. If it predicts you are still speaking, recognition keeps the current turn open for up to about two seconds of continuous silence.
- **Keyword test:** In **Speech**, select an installed keyword model and tap **Test keywords**. Say one keyword and pause. The test shows the phrase the model detected and whether the trailing-silence check passed.
- **Vision:** Install YOLO for pose inference.

### Model Downloads and Development Provisioning

- App model downloads use an explicit Hugging Face, HF-Mirror, or custom HTTPS source; YOLO retains its declared ZIP source. Production revisions remain pinned. Background transfer and resume depend on the OS and server; force-quit does not guarantee continued transfer. See [model resources](../MobileHarness/ModelKit/Support/Config/README.md) and the [Hub adapter](../MobileHarness/ModelKit/Support/Management/HuggingFace/README.md) for acquisition, compatibility, and recovery details.
- For local model development, run `python3 scripts/models/model_download.py <profile>` (for example `gemma4-e2b --platform macos`) to provision `Models/<model>`; `--endpoint` selects the download source. All downloader profiles write to the root `Models/` directory; see the [script inventory](../scripts/README.md).
- Research and engineering reuse verified artifacts in root [Models](../Models/README.md) through their explicit resource settings. App-managed downloads are separate from the development workspace. See [Voice](validation/Voice.md) and [MOSS validation](validation/Moss-Validation.md) for native acceptance procedures.

## Interaction Controls

- **Start / stop listening:** **Press and hold the companion's eyes for half a second** to enable continuous listening, prepare the selected speech capabilities, and request microphone permission. Release after activation; speak, then pause to end the utterance. Partial captions become a final input and spoken reply. Press and hold the eyes again to withdraw listening consent and stop microphone capture.
- **Full-duplex voice:** On an audio route with active echo cancellation, the Assistant keeps listening while it thinks or speaks, using the configured Decision model to classify interruptions. Other audio routes pause recognition during replies and resume it while listening consent remains active. See [full-duplex interaction](../MobileHarness/README.md#assistant-full-duplex-interaction).
- **Camera and photos:** Camera preview starts off. Use the camera controls to open preview, switch lenses, close preview, and grant camera permission. Voice preparation is independent of camera preview. Saving a captured photo requests add-only Photos permission.
- **Error visibility:** The current frontend has no text-entry field. Native and model failures are reported explicitly, and an active inference request stays with its selected provider.
