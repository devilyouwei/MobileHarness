# Camera Values and Capability Catalog

## Summary

Neutral camera interfaces, errors, receipts and seven canonical function definitions.

## Ownership and boundaries

CameraModule binds required CameraControlCapability without owning native sessions, queues, permissions or UI. Host registration chooses call protocol/feedback; role grants remain outside this directory.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Host[Injected CameraControlCapability] --> Module[CameraModule]
 Module --> Definitions[Seven ActionFunctions]
 Definitions --> Entry[CaptureActions]
 Entry -->|Command or photo receipt| Values[Neutral receipt values]
```

## Interface and result semantics

CameraControlCapability supplies setEnabled, retry, target flip, takePhoto, savePhoto/ignorePhoto and owner-scoped JPEG read with opaque FunctionInput correlation. Facing is front/back. CameraCommandReceipt carries acknowledged operation/enabled/facing, not pose readiness. CameraPhotoReceipt carries capture identity/dimensions/MIME; CameraPhotoCommandReceipt carries saved/ignored identity and duplicate-save state.

CameraControlError distinguishes foreground, busy, disabled, permission, unavailable and photoUnavailable producer failures. Unsupported isolated fixture methods throw unavailable; production assembly requires real injection. Catalog completion is value-based for command/photo operations; there is no fallback camera or permission bypass.

✅ Neutral capability, receipts and explicit camera catalog are implemented.

## Related design

[Parent design](../README.md)

## Action-owned documentation and Skill instruction contract

✅ 本目录 CapabilityModule 的 `@ActionCatalog` 从实际 `*Definition` 注册调用（含本类型的本地 helper）生成静态 declarations。添加已有域函数只需修改所属实现及本地依赖绑定，不再同步公共元数据列表。声明投影不捕获设备、处理器或运行会话。


✅ Implemented: CameraPhotoCommandReceipt adds optional feedbackIssues for at most two host-owned bounded visual/audio failures, keeping saved/ignored state honest and backwards-compatible absent-field decoding. No persistence or animation is owned here.
