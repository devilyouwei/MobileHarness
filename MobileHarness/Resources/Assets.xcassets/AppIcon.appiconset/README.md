# Universal App Icon

## Summary

One selected 1024×1024 iOS app-icon image.

## Ownership and boundaries

Owns only AppIcon.png and its asset declaration. Icon choice is build-time, without runtime alternate-icon APIs.

## External relationships and data flow

Arrows show build-time asset/metadata movement; runtime acquisition is owned outside this directory.

```mermaid
flowchart LR
 Artwork[Selected source artwork] --> PNG[AppIcon.png]
 JSON[Contents.json] --> Compile[Xcode asset compilation]
 PNG --> Compile
```

## Asset declaration

`Contents.json` references `AppIcon.png` with universal idiom, iOS platform and 1024×1024 size. Asset-catalog version is 1. The selected image must remain square and compatible with Xcode app-icon compilation.

AppIcon.png 由选择器从居中的 lamp-arm.png 生成：白色机械臂、倾斜手机、青色表情、隐藏背部磁吸座和暗色屏幕。根 README 的 [banner](../../../../output/README.md) 将该图标融入中央手机的概念启动画面，不再单独引用图标；更换 AppIcon 不会自动更新 banner。原生桌面效果须构建并安装 App 验收。

Universal icon image and metadata.

## Related design

[Parent design](../README.md)

## 待实现

- Separate dark/tinted appearance entries.
