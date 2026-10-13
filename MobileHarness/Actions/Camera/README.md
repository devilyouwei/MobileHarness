# Camera Functions

## Summary

Seven camera/photo functions with strict arguments, honest native receipts and injected camera ownership.

## Ownership and boundaries

CaptureActions.swift owns callable bodies; CameraActions is the namespace. App CameraCoordinator owns capture/lease/permission/export; Photographer owns business selection. Functions take no additional camera.capture lease, which would conflict with the native capture owner.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Gateway -->|FunctionInput| Capture[CaptureActions]
 Capture -->|Typed CameraControlCapability| Host[App camera endpoint]
 Host -->|Actual receipt or error| Capture
 Capture -->|Value completion| Gateway
```

## Function contract

| Camera.Capture function | Parameters | Completion |
| --- | --- | --- |
| open / close | None | Native command receipt with operation and acknowledged enabled/facing state |
| flip | Required facing=front/back | Target selection; healthy same-facing idempotence, disabled capture fails |
| retry | None | Explicit native retry/permission path |
| takePhoto | None | photoID/width/height/MIME after actual capture/presentation boundary |
| savePhoto / ignorePhoto | Optional photoID UUID | Actual saved/ignored receipt, UUID and alreadySaved where applicable |

Reject unknown parameters and malformed/oversized UUIDs before effects. Cancellation is checked before/after native work. Save has a 60-second cooperative budget; no camera command queue exists in the function domain. App rejects overlap and stale foreground/root/task ownership. open does not promise model readiness; close joins native/perception cleanup.

Host binds scheduled Actions and fixed returning Tools; Photographer model declares Camera Actions only. Direct typed UI publication and conversational Photographer task selection use the same functions. Photo read authorization retains original source/session/input; no fabricated capture/album success is returned.

✅ Typed camera commands, capture and photo disposition are implemented.

## Related design

[Parent design](../README.md) · [Support](Support/README.md)

## Action-owned documentation and Skill instruction contract

✅ 本域函数用 `@Action(doc:parameters:)` 维护说明与参数契约。所属模块注册自动生成声明投影；业务顺序和调用示例由 Skill Instructions.md 教学，不再登记 examples。

## Channel-owned Action ordering

✅ Function metadata and business attributes have no serialization key. Scheduled ordering belongs to [ChannelScheduler](../../Gateway/Output/Scheduling/README.md); resources/budgets and native capability admission remain explicit.


✅ 提示词精简已实现：摄影函数doc保留实际效果、结果及独有边界，移除重复流程/调度教学；Photography集中编排，参数/执行/超时不变。


✅ Implemented: savePhoto/ignorePhoto join host departure effects after native success. Actual saved/ignored receipts can carry optional feedbackIssues; errors in effects cannot undo album import. Explicit duplicate saved UUID is idempotent after UI removal. Permission/import failure retains the current photo.
