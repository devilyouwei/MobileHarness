# ADR0144 — Shared Read-only History Tools

Date: 2026-10-06. Status: implemented.

## Decision

Add History.list/read to Tools and Assistant JSON v5. Production composition injects HistoryQueryService with the existing journal. Tools owns preview/query policy; StorageChat retains persistence and raw records. BehaviorAssembly receives HistoryQueryCapability, with no Storage import or implicit default implementation.

Calls use required string parameters, matching the native Tool parser. List pages include at most five conversations; read pages include at most two turn previews. Unicode-safe prefixes explicitly report truncation; encoded results above 1800 bytes fail rather than disappear or exceed Assistant's existing 2000-byte immediate-result admission. IDs and raw text remain data, never executable output. Each page uses a fresh snapshot; pagination is not transactional across calls.

## Consequences

✅ The first shared history capability is available to cloud-native model calls through authorization, returning execution and correlated InputGateway feedback. No new Agent, store, queue, deletion or history replay is introduced.

❌ History UI remains on the existing workflow, BLE Tool exposure remains pending, and Assistant still renders escaped Tool feedback without model continuation. This stage does not claim complete conversational history navigation or semantic search.

## Validation

✅ Six final focused tests and unsigned iOS device build passed; all 480 full-run integration tests passed. ❌ Full check.sh retained one audio diagnostic workflow timeout (isolated rerun passed); simulator CoreAI availability remains blocked. See [dated evidence](../validation/Validation-History.md#2026-10-06--shared-read-only-history-tools).
