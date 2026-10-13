# Cloud chat tests

Purpose: independently verify the OpenAI-compatible adapter without network access or real credentials. Design goals: protocol fidelity, bounded parsing and shared ModelManager lifecycle.

✅ Request path/auth/encoding, invalid configuration, bytewise Unicode SSE, CRLF, multiline events, malformed/unsupported/oversized output, URLProtocol-backed streaming, context identity, unload/reload, concurrent-request rejection, cancellation, HTTP error sanitization and shutdown rejection.
❌ Live third-party compatibility, real authentication and physical-device networking acceptance require separately supplied endpoint/credentials.


✅ Added model-list validation and replacement tests, including candidate-failure preservation, active-session cancellation, old-handle rejection and unrelated-provider identity. ❌ UI and Keychain tests are separate from this target.

✅ Offline tests verify blank endpoint fallback, missing Authorization for empty credentials on chat and discovery, surfaced HTTP failures, and raw model discovery preservation. ❌ No live credentials or provider calls are used.

✅ Chat output-token budgets are optional and default to nil. Assistant/cloud requests omit max_output_tokens so the provider chooses its default; local Gemma 4 E2B uses remaining room in its existing 4096-token context. History omits max tokens display and preserves older explicit budgets on disk. The separate 2000-byte whole-reply cap is removed; parser, queue, timeout and per-segment bounds remain. Explicit title/warmup budgets are unchanged. ❌ Live-provider/device acceptance remains separate.

✅ Offline regressions cover delayed/slow consumption of 127, 128 and 1,024 Unicode text events plus terminal completion, cancellation or shutdown after pausing consumption, and successful reuse after cancellation/unload. Unload runs after consumption or cancellation. Fixtures use URLProtocol without live credentials. Shared SessionTests separately verify suspension at a full queue and cancellation waking a blocked producer.

✅ Responses usage regression covers terminal-response counts before finished, malformed/negative/duplicate counts, store=false request encoding and URLProtocol delivery. ❌ Live-provider compatibility remains separate.


## Completion batch — provider presentation and capability policy

✅ Implemented: provider discovery model-family eligibility belongs to Actions ProviderModelList; ModelKit validates/decodes raw IDs only. Preserve filtering/dedup/order and bounds at the app boundary. SettingsState becomes a passive editable snapshot, with no tasks or injected execution; SettingsInteractionWorkflow in the existing Settings directory owns bounded form admission, revision and page-independent saves. UI forwards edits/discovery/cancellation/save through SettingsControlling.

✅ Implemented: presentation-enabled provider intents select a second registered UI.ResourcePresentation.showProviderResult call after the business call, on success or failure. Headless requests retain one call. Private result lookup and revision/session fences prevent credentials in protocol payloads and stale form updates. One attempt only, no recursive presentation/replay; producer and presentation failure chains remain distinct. App injects the native UI endpoint; business functions remain independent of UI and call protocols.


## Bounded native result continuation

✅ Implemented: Synthetic native-capable Agents correlate model-native calls with runtime-only feedback under the original turn, awaits complete results and requests the next model round. Limits: four total model rounds,16 native calls,64 KiB aggregate feedback/transcript and no Agent generation or round-feedback time limit. A failed call becomes data for the model, never an automatic function retry. Cancellation clears owned feedback state and joins model cleanup; unknown/stale/duplicate feedback cannot resume a turn. Internal UI receipts retain their handling; the static /status shortcut is retired.

✅ Implemented: ModelKit ChatMessage gains provider-neutral assistant tool-call declarations and tool-result messages. OpenAI serializes request-local aliases consistently across declarations and prior calls; Gemma rejects native transcripts explicitly. Storage keeps optional exact continuation request JSON bytes as data, with bounded records and unchanged v1 compatibility. Camera native model calls use returning protocol registration so actual completion/error can continue reasoning. No change to camera or NexArm function implementation.

## Assistant photo observation — ADR0184

✅ Implemented: Verify exact Responses input_image encoding, old text-only behavior and image modality limits without remote API calls.

❌ Real camera/shutter/animation and configured-model vision acceptance remain pending; video recording and system Photos export are outside this iteration.


✅ Offline timing regressions: URLProtocol-backed requests produce provider timestamps and nonnegative elapsed time; empty/pre-start text is ignored, start is idempotent and later text cannot overwrite first evidence. No credentials or network requests; physical networking latency remains unmeasured.


## Responses and Action-only Assistant migration

✅ Implemented: Replace Chat Completions fixtures with offline Responses SSE and request assertions. Cover terminal status/usage, input and image items, function pairing, refusal/failure/unknown output, fragmented Unicode, cancellation then reuse, one session across sequential operations, unload/replacement cleanup and unchanged TTFT sampling. No live credentials/network calls.

✅ Request regression: Responses historical assistant text must use output_text (annotations=[]), including assistant messages that also declare native calls; system/user text remains input_text. Live acceptance evidence belongs in docs/Validation-History.md, with credentials excluded from test sources and output.

## Startup publication and foreground task regression

✅ 本地请求编码回归验证所有原生 Tools 的 strict=false，并验证带可选属性的 Schema required 不被扩展。使用合成配置，不调用真实 API。

## Lifecycle-owned conversation and audio (2026-10-12)

✅ 已移除对话生成、ReACT、收件箱排队、结果屏障、ASR 收尾、TTS 合成及回复占用租约的计时终止。Signal 默认无过期时间，框架不再按通信契约附加 TTL。保留显式实时感知数据的新鲜度和网络传输自身超时；它们不作为对话/语音缓存生命周期。Action 自身超时通过原始执行者的 ActionResult 返回。请求/调用数及队列/PCM 容量仍有界，不以计时自动删除已接纳输入。语音句柄无读等待或错误记录 TTL，按播放完成、输入/会话正常结束、异常或显式取消清理；取消加入生成和播放工作。

✅ 覆盖已释放工具的历史call/output在当前无tools或不同tools时仍完整编码；不重新声明历史工具，当前输出名称映射不扩大。


✅ 覆盖credit_balance_exhausted从error与response.failed保留code；无合法code仍按原invalidResponse处理。

## Consecutive user message boundaries

✅ Implemented: Offline assertions verify original consecutive-user message and multimodal boundaries. The live-provider probe sends the original six-message transcript through OpenAIChat.chat(), with encoded roles matching every source message. Reasoning/private-channel and native-pairing regressions remain.

## Explicit live-provider request probe

✅ Implemented: opt-in liveProviderPreservesConsecutiveUsers uses HARNESS_LIVE_CHAT_URL/KEY/MODEL supplied by the invoking process, never reading or committing credentials in test sources. It calls the actual OpenAIChat capability with synthetic consecutive-user history, checks encoded user roles/parts, consumes streaming completion and joins model cleanup. On failure, one explicit diagnostic request captures a bounded, key-redacted provider error; normal tests remain offline. Real-provider evidence and compatibility limits belong in docs/Validation-History.md.

## Responses reasoning compatibility

✅ Implemented: offline regressions verify Alibaba-style reasoning item/delta/done sequences produce only final answer text and usage/completion; reasoning before a native call preserves its original output index and exact pairing. Malformed reasoning/text fields, unknown outputs, truncated completion and existing byte bounds remain explicit errors. Live-provider probes report encoded roles and metadata only, never credentials or private reasoning text.

## Non-thinking request policy

✅ Implemented: offline wire assertions cover Alibaba Cloud workspace/dashscope hosts with reasoning.effort=none and top-level enable_thinking=false, canonical OpenAI IDs through native/proxy URLs, unchanged GPT-4/unknown model payloads, explicit mandatory-thinking rejection and title-shaped 64-token requests. Existing tool/image/usage/lifecycle and private-channel regressions remain. The live chat probe records real first-text timing with the same request flags; no secrets, user history or private reasoning text are printed.
