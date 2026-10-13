# Conversation and Task History Adaptation

## Summary

Reads the Assistant repository, adapts immutable UI values and transports Assistant-history operations directly to Memory.

## Ownership and boundaries

Assistant, Photographer, Memory and ApplicationControl own distinct contexts. History never copies a writable archive or starts a model for reads. Task history projects Assistant-owned foreground and background records; Assistant archive/delete/title uses Memory with trusted confirmation.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 UI -->|Read or confirmed history intent| History
 Repositories[Assistant context repository] -->|Immutable snapshot| History
 History -->|Memory intent| Gateway
 Gateway --> Agents[Memory]
 Agents -->|Registered operation| Gateway
 Gateway --> Actions[History functions]
 Storage -->|Owned photo bytes| History
 History -->|UI-owned values and parser preview| UI
```

## Interfaces and projection

ConversationHistoryWorkflow owns one load/operation task per destination. HistoryPresentationAdapter copies the bounded Codable snapshot into UI-owned HistorySnapshot values and projects foreground input membership from AgentTaskSkillState.tasks and background state from the Assistant task registry/taskViews. Goals supply titles; ReACT and later inputs stay together across archives. Missing dates remain empty.

HistoryIntentRuntime admits one Memory operation, consumes bound outputs and awaits correlated business completion with a 120-second watchdog. Cancellation joins dispatch and retirement; loading/mutation does not create an Assistant delegation task. Producer execution and later delivery failures remain distinct.

## Images and parser previews

Image references contain ID/MIME/byte count, not bytes. Reads validate selected Agent/archive/turn association and the exact producing input/owner before accessing CapturedPhotoStore. At most four image reads run; oversized or unassociated references fail. Missing photos do not become synthetic images.

HistoryAgentAdapter uses the exact persisted Assistant request catalog and shared segmentation. Parsing preview reports valid/rejected calls and wait boundaries without executing them. Model request rows preserve input, output, timing, usage and metadata-only context; observation continuations are presented as ReACT.

✅ Assistant conversation/task projections, scoped image loading and Memory mutation transport are implemented.

## Related design

[Parent design](../README.md)

## Skill/task-mode contract

✅ HistoryPresentationAdapter provides complete Assistant conversations, an additional foreground/background task grouping. Task membership is persisted, not inferred from current mode. Task grouping is presentation-only; mutation/export still use canonical Context transactions and active-task protection.

## Task/history regression correction

✅ 本次修复：Assistant 对话页展示完整持久化输入/回复（含 Task），任务页仍提供分组投影。开始新对话先通过现有 Task 控制取消等待任务，再交 Memory 归档；生成期间拒绝归档，不撤销设备效果。

✅ 忙碌归档在页面显示“正在回复或处理输入，请结束后再开始新对话”，不向用户暴露 scopeClosed。

## 历史记录收敛（2026-10-13）

✅ 已实现：HistoryPresentationAdapter.assistantTasks 使用 Assistant 的 TaskRecord.inputIDs 关联前台请求，使用 registry/taskViews 展示后台任务。删除 specialist 旧聊天投影和未关联输入伪任务；保留 Memory 事务、取消和照片读取权限。

❌ 历史记录页面板块重新设计及原生 UI/真机验收。
