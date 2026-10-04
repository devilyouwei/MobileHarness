# Cloud chat tests

Purpose: independently verify the OpenAI-compatible adapter without network access or real credentials. Design goals: protocol fidelity, bounded parsing and shared ModelManager lifecycle.

✅ Request path/auth/encoding, invalid configuration, bytewise Unicode SSE, CRLF, multiline events, malformed/unsupported/oversized output, URLProtocol-backed streaming, context identity, unload/reload, concurrent-request rejection, cancellation, HTTP error sanitization and shutdown rejection.
❌ Live third-party compatibility, real authentication and physical-device networking acceptance require separately supplied endpoint/credentials.


✅ Added model-list validation and replacement tests, including candidate-failure preservation, active-session cancellation, old-handle rejection and unrelated-provider identity. ❌ UI and Keychain tests are separate from this target.

✅ Offline tests verify blank endpoint fallback, missing Authorization for empty credentials on chat and discovery, surfaced HTTP failures, and chat-family filtering with third-party deployment preservation. ❌ No live credentials or provider calls are used.

✅ Chat output-token budgets are optional and default to nil. Assistant/cloud requests omit max_tokens so the provider chooses its default; local Gemma 4 E2B uses remaining room in its existing 4096-token context. History omits max tokens display and preserves older explicit budgets on disk. The separate 2000-byte whole-reply cap is removed; parser, queue, timeout and per-segment bounds remain. Explicit title/warmup budgets are unchanged. ❌ Live-provider/device acceptance remains separate.

✅ Offline long-reply regression queues 1,024 Unicode text events before starting the consumer and verifies every fragment plus the terminal finish reason. Producer completion is joined through resource unload; no timing sleeps or live credentials are used.

✅ Usage regression covers trailing SSE usage before [DONE], malformed/negative/duplicate counts, include_usage request encoding and capability delivery before finished with a URLProtocol fixture. ❌ Live-provider compatibility remains separate.
