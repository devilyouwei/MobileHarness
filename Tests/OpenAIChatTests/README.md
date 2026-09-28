# Cloud chat tests

Purpose: independently verify the OpenAI-compatible adapter without network access or real credentials. Design goals: protocol fidelity, bounded parsing and shared ModelManager lifecycle.

✅ Request path/auth/encoding, invalid configuration, bytewise Unicode SSE, CRLF, multiline events, malformed/unsupported/oversized output, URLProtocol-backed streaming, context identity, unload/reload, concurrent-request rejection, cancellation, HTTP error sanitization and shutdown rejection.
❌ Live third-party compatibility, real authentication and physical-device networking acceptance require separately supplied endpoint/credentials.

Validation (2026-09-28): six offline tests passed using a temporary manifest symlinked to the original sources, isolating concurrently changing Kokoro targets. Adapter and test formatting passed. Root check encountered unrelated FluidAudio/Kokoro formatting errors; full iOS build encountered the concurrent KokoroInput.Segment compile error. ModelKitOpenAI compiled for simulator arm64 and x86_64 before that failure. No live requests were made.

✅ Added model-list validation and replacement tests, including candidate-failure preservation, active-session cancellation, old-handle rejection and unrelated-provider identity. ❌ UI and Keychain tests are separate from this target.

Validation (2026-09-28): root scripts/check.sh passed, followed by all nine OpenAIChatTests after the final discovery case was added. scripts/build-ios.sh passed all four simulator schemes. The simulator App installed and launched. Computer-use access to Device Hub timed out, so toolbar placement, settings interactions and animation have not been visually accepted. No real cloud credentials or live chat request were used.
