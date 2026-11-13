# MobileHarness 技术文档核对验证

2026-11-14。范围见 [归档](../completed/Readme-Ownership-Audit.md)。

- 核对版本控制中的 136 份 MobileHarness README。17 份简单叶目录文档并入直接父层，其余 119 份保留。检查保留文档中的 1063 处相对路径及锚点，并核对仓库其他文档指向受改动章节的引用。
- 用项目内置 Mermaid 12.3.0 在无头 Chrome 逐张解析和渲染 120 张图，确认生成 SVG。抽查一级模块图的标签、箭头和布局。将较宽的语音、视觉、模型适配和 Assistant 链路改成更紧凑的方向或标签。
- 对照 SwiftPM 解析结果和 Xcode 工程对象，确认仅删除对应的 README 排除项和导航引用。17 个合并目录均有直接父层链接，目录覆盖、模块边界、Xcode 配置检查和 `git diff --check` 通过。
- `./scripts/check.sh` 首次停在工作区既有的 Swift 格式问题。工作区随后更新后重跑返回 0，格式、主测试阶段、`LiveRuntimeTests` 的 228 项测试和 plist 校验通过。输出在 `cameraNativeMetalDrawStopAndLayerHandoff` 开始后没有给出该用例或 `NativePresentationTests` 的终态。独立运行该 suite 复现同一日志边界。仅跳过该 Metal 用例后，其余 13 项原生呈现测试通过，该用例结果仍未确认。
- 此次未运行 iOS 构建、真实模型推理或物理设备验收。
