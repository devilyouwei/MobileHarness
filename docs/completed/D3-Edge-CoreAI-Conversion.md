# D3 Edge Core AI conversion and publication

Date: 2026-11-10 (Asia/Shanghai).

## Scope and ownership

Convert vllm-sr/d3-edge into Apple Core AI assets, validate against its pinned original runtime, and publish the tested artifact under hugging-mac. Use Decision terminology. This task does not integrate a provider into MobileHarness or rename existing Swift contracts.

The user approved /Users/devil/Pro/d3-edge-coreai and its required subdirectories for isolated dependencies, source weights, conversion code, assets and evidence. Model weights and environments remain outside this repository. Existing application changes are unrelated and must be preserved.

## Intended files and behavior

- This plan records scope and acceptance; docs/validation/D3-Edge-CoreAI.md will record actual evidence and publication identity.
- The external workspace owns convert.py, a Python host adapter, pinned dependencies, test cases, validation reports, licensing, model card and publication staging.
- Reuse and attribute the Apache-2.0 community conversion recipe from maxffarrell/d3-edge-CoreAI, with changes recorded explicitly. Pin both recipe and original source revisions.
- Preserve noncausal full-attention layers, causal DeltaNet layers, original option ordering/prompt template, last-valid-token readout and FP32 head. Neural execution uses Core AI; tokenization and typed response assembly remain on the host.
- Begin with a bounded 512-token export and 224-pixel vision encoder to reproduce an established conversion. Reject oversized inputs without truncation. Record any scope changes before implementing them.
- Work is owned by CLI processes independently of UI lifetime; use bounded sequential validation and explicit subprocess failures. No unbounded task queues or silent backend fallbacks.

## Acceptance and publication

1. Install an isolated environment and download only pinned source/recipe files.
2. Export the decision and vision graphs locally and prove native Core AI loading/inference.
3. Compare original and converted outputs on synthetic English/Chinese choice, binary and score questions, repeated calls, input limits and representative visual cases. Record all failures and numeric drift; distinguish conversion fidelity from task correctness.
4. Measure warm inference latency and peak process memory on this Mac; do not imply iPhone, ANE placement, power or full-resolution equivalence.
5. Test the distributable package without requiring original model weights, verify file checksums and license attribution, then upload an explicit file allowlist to hugging-mac/d3-edge-CoreAI. User has authorized publication after testing. Never upload tokens, caches, unrelated files, private inputs or original weight duplicates.
6. Record remote revision and verify the published file inventory. This repository has documentation-only edits; validate paths and diff formatting. Native application builds are not conversion validation.

## Delivery

Completed on macOS 27.2 / Apple M5 / 16 GiB with Xcode 27.0. Text-only Core AI conversion, reference comparisons, offline package checks and independent Swift native inference completed. Published publicly to [hugging-mac/d3-edge-CoreAI](https://huggingface.co/hugging-mac/d3-edge-CoreAI), revision `0690c04ee1640c1c3fa11a882323751dda6d086a`; verified 41 uploaded files by remote sizes, available LFS hashes and a downloaded checksum manifest. The user authorized both the isolated workspace and publication after testing.

The artifact is experimental: 75/75 baseline choices match; expanded prompt comparisons include one near-tie disagreement. Best full-duplex business result is 35/48, not production acceptance. No application provider integration, live audio or iPhone acceptance was included. Detailed results and limitations: [validation](../validation/D3-Edge-CoreAI.md). Earlier planning below records the user-directed refinement from multimodal exploration to the delivered text-only scope.

## Full-duplex speech decision scope refinement

The user clarified that the actual business input is speech transcription and the three decisions are interrupt, discard and enqueue. Prioritize a text-only artifact and adapter; omit the vision graph and media inputs from the publication. This avoids unnecessary vision weights and preprocessing. Preserve the original text decision semantics and 512-token capacity.

Validation must include both conversion fidelity and independently specified business expectations. Each synthetic case supplies ASR text plus relevant assistant playback and conversation context. Initial policy: explicit stop/cancel or urgent correction interrupts active output; noise/echo or acknowledgments requiring no reply are discarded; useful deferrable requests enter the queue. Ambiguous cases and idle-state handling must be documented rather than presented as universally correct labels. Deterministic ASR-final/echo gates and actual audio cancellation/queue execution remain application responsibilities outside this model conversion.

The external conversion script will export only text input IDs, attention mask and positions, and the original 255-way FP32 readout. The adapter will reject media and overlength input explicitly. Validation adds labeled Chinese full-duplex cases, class confusion, harmful false-discard and false-interrupt counts, paired-context cases, and repeated warm latency. No live microphone/audio or iPhone acceptance is implied.

Initial native validation completed 75 cases, including 48 labeled full-duplex cases. The first long-policy prompt scored 24/48 against the declared business labels. Preserve this baseline. Run a bounded comparison of two shorter prompt formulations on the same frozen cases, with an independently computed original-model comparison for any proposed example prompt. These are exploratory prompt-development results, not held-out accuracy; no labels or source model weights will be changed to improve reported results. Publication must distinguish a working converted artifact from readiness for full-duplex production routing.
