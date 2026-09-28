# Cloud chat tests

Purpose: independently verify the OpenAI-compatible adapter without network access or real credentials. Design goals: protocol fidelity, bounded parsing and shared ModelManager lifecycle.

✅ Request path/auth/encoding, invalid configuration, bytewise Unicode SSE, CRLF, multiline events, malformed/unsupported/oversized output, URLProtocol-backed streaming, context identity, unload/reload, concurrent-request rejection, cancellation, HTTP error sanitization and shutdown rejection.
❌ Live third-party compatibility, real authentication and physical-device networking acceptance require separately supplied endpoint/credentials.


✅ Added model-list validation and replacement tests, including candidate-failure preservation, active-session cancellation, old-handle rejection and unrelated-provider identity. ❌ UI and Keychain tests are separate from this target.

✅ Offline tests verify blank endpoint fallback, missing Authorization for empty credentials on chat and discovery, surfaced HTTP failures, and chat-family filtering with third-party deployment preservation. ❌ No live credentials or provider calls are used.
