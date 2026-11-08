# Complete request logs and independent clearing

后续设计（2026-11-07，已完成并归档）：[独立 Agent 业务与纯通信表方案](Message-Agent-Business-Separation.md) 保留两侧私有任务/消息，agent_messages 为通用纯通信；model_request_log 独立保存实际 HTTP、Prompts 图片和 generation meta。清空日志不删除通信或业务，不从相册回退图片。下文中立 ChatRequest/ChatEvents、“not HTTP/SSE”和 timing 保留描述当时实现，不是新目标；旧日志不能补造 HTTP 字节。原始 HTTP 采集、新十表及调用方已经实现；整体验证与清洁真机安装已完成，证据跟随该后续方案。

2026-11-07 approved: preserve actual submitted model images as Base64 in complete request logs, without additionally saving Camera originals. This supersedes ephemeral-photo-only history retention. Logs are optional debugging evidence, independent of conversation/message business data.

## Responsibilities and changes

- Agents/Support/Chat records complete neutral ChatRequest (messages, actual images, tools, parameters and request context) before provider execution and ChatEvents on completion/failure. These are model inputs/events, not HTTP headers or raw SSE. Writer shares this mechanism and no longer saves screenshot files merely for history.
- Storage/Database/Chat exposes explicit log write/read/delete operations. SQLite renames the previous mixed-purpose model_request_log to model_requests, retaining request identities, relationships, replies, Action results, timings, task metadata and ordering. A separate optional model_request_log contains request_id, request_json and response_json only.
- Upgrade the known current schema in a transaction: rename the business table, move available payloads, remove raw prompt/event fields from business detail_json and drop its obsolete request_json column. Preserve IDs and all conversations, messages, tasks and media; do not reset the database for this change. Old logs cannot gain missing image bytes retroactively.
- Initialize a log once before execution. Terminal/error callbacks only update an existing row; ordinary business checkpoints never write logs. Clearing while a request runs therefore cannot be undone by its late completion.
- Writer continuation rebuilds bounded user/reply/native-tool pairs from business request evidence, independently of deletable logs; it no longer restores old prompt JSON. This prevents log deletion from changing continuation behavior.
- Explicit request detail and complete export hydrate payloads. Lists and live model context use lightweight business records. Each request/event payload is limited to 32 MiB with explicit failure, never truncation; logs have no automatic retention eviction.
- Clear physically deletes one request_N log or all model_request_log rows (Assistant and Writer together). It does not delete conversations, messages, requests, replies, Action details, timing, tasks, workspaces or media. No tombstones and no per-field clearing.
- Memory routes user clearing through its internal History action; Writer owns its records interface. Only LLM-generated actions may drive ReACT. UI adds a per-request clear button in conversation detail and a global clear button in history lists, with confirmation. Only Prompts becomes 已清空; other detail blocks remain available. Images render from logged bytes independently of the Camera cache.

## Documentation and validation

Update Storage/Chat/SQLite, shared Chat, Writer, Memory, Actions/History, UI/Settings and overall technical READMEs with implemented boundaries. Reuse existing directories/targets.

Test binary round-trip after database reopen, lightweight list/context, physical single/global deletion, both-agent scope, preservation of business rows/output/actions/timing, late-write isolation, migration/FK integrity, cleared UI projection and full export. Run ./scripts/check.sh and ./scripts/build-ios.sh and inspect native test completion. Record physical-device/native visual/real-model acceptance separately; never clear user logs during automated validation.
