# ADR0165 — Agent-selected archive and title operations

Accepted: 2026-10-07. Implemented; owning designs updated first.

Extend typed history.intent/1 with startNew and summarize(UUID). ConversationMemory owns deterministic sequencing and fixed permissions for History.Conversation.startNew/summarize; Assistant retains read-only model permissions. Title inference is a non-executable computation helper under ConversationMemory, injected by App into Actions through a narrow closure. App prepares the current chat capability; Actions owns callable archive/title effects and journal validation. Storage remains an atomic data library.

Archival commits before title inference. Show the committed archive before the title call. Empty current history creates no archive/title work. Preserve title inference limits and rejection of executable model output. Failure/cancellation saves a bounded retry error while retaining raw history, then propagates; no auto retry, rollback or replay. The facade holds no journal or inference callbacks. New transport sequences have a six-output bound and terminal controls; one active request and eight-output cancelled drain remain. Successfully delivered handler feedback determines Agent follow-up; dispatch/delivery failures abort.

✅ Final check.sh passed, including520 integration tests,36 workflow tests, boundary checks, formatting and metadata. The additional inference-plus-retry-persistence failure regression passed separately and retained both report causes. Targeted history flows passed through real Gateways and callable functions. Unsigned iOS device build and all six packaged Agent configurations passed. All192 MobileHarness Mermaid diagrams parse; local documentation paths resolve.

❌ Required build-ios.sh remains blocked in its first simulator scheme by external CoreAIShared failing to resolve CoreAI; later schemes were not attempted. No new real-model/native UI or physical-device acceptance was performed. Navigation, registered failure wording, conversational mutations and general LLM continuation remain separate stages.
