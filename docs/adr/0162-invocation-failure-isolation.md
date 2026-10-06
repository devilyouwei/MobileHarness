# ADR0162 — Invocation failure isolation and complete results

Accepted: 2026-10-06. Active Agent-Driven-App.md updated before implementation.

Normal callable failures end only their invocation. Gateway preserves child reports, neutral producer codes and bounded terminal causes in the shared ActionCompletion before adapting scheduled/native feedback. Accepted scheduled native failures become result reports; admission failures and explicit owner cancellation retain their existing scope. Cleanup joins before releasing resources. Feedback delivery failures never replay effects.

Business implementations, NexArm arrival criteria and timeout calculation are unchanged. ✅ check.sh passed, including all508 integration tests and37 workflow tests. Both direct and scheduled native regressions preserve structured producer failures and execute the next call successfully. Existing native error-text compatibility tests pass. ✅ Final unsigned iOS device build and six packaged Agent configurations passed. ✅ All193 MobileHarness Mermaid diagrams parse. ❌ Required simulator build remains blocked by the external CoreAIShared dependency on unavailable CoreAI; later script schemes were not attempted. No physical acceptance is claimed.
