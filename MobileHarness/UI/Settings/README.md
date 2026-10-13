# Settings and History Presentation

## Summary

Local settings drafts/navigation, resource/device snapshots, audio detection and read-only model history rendering.

## Ownership and boundaries

Injected controls submit operations to App owners. UI owns localization, selection, presentation fallback and independent record schemas; it does not import Storage, Agents, Actions or device SDKs.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 App -->|drafts, snapshots and control protocols| Settings[Settings state and views]
 User -->|edit and navigate locally| Settings
 Settings -->|save, discover, acquire, device or history operation| App
 App -->|actual outcomes and revision-fenced values| Settings
```

## Forms and resources

`CloudSettingsDraft` contains editable endpoint/model/key fields; credentials never enter model history or user logs. `SettingsControlling` handles restore/save/discovery and cancellation of page-scoped discovery. Draft revisions fence late results; navigation does not submit forms.

`ModelResourceGroup` presents recognition, synthesis, language and vision while preserving catalog IDs. Recognition activation requires Nemotron, synthesis requires MOSS; Silero availability is independent. Download never automatically enables custom speech. `ModelResourcesState` applies only the current refresh generation and displays queued/downloading/installing/deleting/cancelling facts supplied by the host.

## Device and audio detection

`BluetoothSettingsState` separates availability, discovery, connection phase, transport issue, control capability and recovery stage. Tapping a disconnected row submits connect; tapping a connected row opens local detail. Native recovery/manual workers are host-owned. Slider release/stop submits actual stop intent; connected does not mean physically verified.

`AudioDetectionSnapshot` distinguishes native input/support, actual spatial/mono layout, fallback, PCM freshness and direction evidence. More than one second without a frame becomes no-audio. Controls delegate one whole detection endpoint; no direction algorithm or microphone owner lives in UI.

## History

Agent destinations are Assistant, Photographer, Memory and ApplicationControl. Each has independent state and one host-owned load slot. Assistant renders current/archive controls; specialists render read-only task lists and task-scoped detail/export. Original task requests supply titles; missing task association stays separate. UI does not invent dates, usage, timing or outcomes.

`History*` values are presentation-owned. Actual request order, ReACT (orange), native calls/results, usage and optional adapter-recorded request-start/first-token latency are retained. Generation metadata renders directly under Generation Meta. Timing is never inferred from record arrival. Unavailable provider values remain blank. Exports preserve supplied evidence and real failures, without injecting storage-migration explanations.

Up to four image references are deduplicated from actual context. Page-cancellable reads allow at most 4 MiB per image; asynchronous UIKit preparation bounds thumbnails to 320 pixels and preview to 2048 while preserving aspect ratio. Actual failures offer retry; absent photos remain blank. Only structured imageReferences supply image identity; displayed text stays literal.

✅ Local drafts/navigation, independent resource/device/history values and bounded image presentation.

❌ History page layout redesign.

## Related design

[Parent design](../README.md)

## Skill/task-mode contract

✅ “历史记录” contains Assistant 聊天记录 and 任务记录. Request details show immutable task/Skill/function evidence outside collapsed generation information; only stored modelRequests become request rows.

## 泛化 Task 与独立 Skill

✅ Task rows/details display execution type, goal, Skills, executor, parent task and last result/progress. Model rounds show immutable taskGoal/execution/Skill revisions separately from collapsed generation information. Unavailable evidence remains absent.

✅ 音频完成等待使用原生回调、实际错误及作用域取消，不设置 ASR/TTS 收尾、PCM 首帧或播放 buffer 兜底计时器；移除相应不存在的 timeout/fallback 展示分支，完成仍须真实完成回调，不能伪造成功。

## 历史记录收敛（2026-10-13）

✅ 已实现：SettingsView/ConversationHistoryView 显示“历史记录”，仅有 Assistant 聊天记录与任务记录。ConversationHistoryPresentation 仅展开 modelRequests、只解析结构化图片引用；删除旧续轮合成、虚构身份、缺失元数据标签与 Mode 回退。HistoryTask 只表示实际任务，取消未关联输入分区。

❌ 历史记录页面板块重新设计及原生 UI/真机验收。


## Task history indexing and in-place compression

✅ Implemented: Conversation history v2 shows Task summary cards at their original request position, with goal/status/reported summary/failure and expandable raw request evidence. Task details use exact historyTaskID membership. Current/archived conversations and exports retain source diagnostics; no old history decoder is provided.

✅ Ordering: each admitted model request receives a monotonic historyOrder from the archive revision. Order the flattened timeline and compression sources by this value, not parent turn order or wall-clock timestamps; a continuation can interleave with later user inputs. History facade refreshes authoritative revisions and rejects stale commits.


## 会话存储性能重构 v3

✅ 已实现：HistoryModelRequest/HistoryTurn 用 response 字符串替代 fragments；归档列表占位保留ID、时间、标题和计数。详情进入后加载单个会话并显示加载/失败状态。

✅ 普通列表的当前会话也只投影元数据；正文仅保留一个 selectedConversation，标题异步刷新列表不清除所选正文或照片关联。

## 历史列表布局与单级详情导航

✅ ConversationHistoryView keeps task metadata, expansion controls and original-request cells independent, but renders the complete timeline in one contiguous Section without inter-item margins or task headers. Request rows use 12-point top/bottom insets plus 8-point internal vertical padding and native separators. Task goals/checklist icons remain blue; ordinary timeline requests use text bubbles, expanded task requests have no icon. ReACT text stays orange and its badge follows the bottom date/status text. Expansion remains immediate with the existing single-destination navigation.

✅ ConversationHistoryState defines a UI-local HistoryRequestNavigation value with one selected request and one presentation flag; repeated taps during an active destination do not replace or append it. ConversationHistoryDetail registers exactly one navigationDestination outside List rows, uses plain Buttons to select requests, and retains expansion state after Back/interactive dismissal. Task-scoped request lists use the same single-destination contract. Async detail loading checks cancellation before applying results. No storage, backend or module interfaces change.

❌ Native expansion layout, interactive Back and repeated navigation acceptance remain separate from state regressions and iOS compilation.

✅ Timeline outer/top edges remain hidden. First-level conversation/task boundaries span both card edges. Task metadata/internal source boundaries start at the primary text column (16-point padding + 24-point icon + 12-point gap); expanded source text uses that same 52-point leading inset. The last source closes the task with a full-width separator. Expansion control aligns with task text, using an inset line when expanded and a full-width boundary when collapsed. HistoryTimelineRowSeparator accepts a leading alignment offset and extends its trailing edge through the 20-point content inset. Native simulator screenshots of production page code with synthetic records verify collapsed/expanded static geometry; provider/persistence and gesture acceptance remain separate.

## Detail headings and JSON sharing

✅ ConversationTurnDetail retains the six English section titles. decisionMetadata.catalogJSON's Function Catalog disclosure belongs to Tasks and Skills; Prompts retains actual context messages and sent declarations. Parsed Output and Metadata disclosure rows and the obsolete generationInfoExpanded state are removed. Their existing contents render directly in Action Execution and Generation Meta. Parsed interpretation still comes from controls.preview and is not execution evidence; no data/share/navigation contract changes.

✅ HistoryTask is Codable; the presentation JSON encoder uses pretty printed/sorted keys, default Codable dates and a 32 MiB output limit. A native Transferable JSON document uses the unmodified UI-owned conversation/task/request value, including original requestJSON strings and evidence. Encoding happens only when the share provider requests data, with cancellation checks and thrown failures; no file writes, view-body serialization, diagnostic report, fabricated empty export or storage API change. Conversation timelines share loaded full conversation JSON, task timelines share task JSON and request details share the displayed request JSON. Metadata is not substituted for a conversation that is still loading.

❌ Native receiving-app file acceptance remains separate from Codable regressions, simulator layout and Transferable/device compilation.
