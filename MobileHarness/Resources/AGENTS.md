# Resources 开发规范

适用于本目录及其子目录。先读[仓库规则](../../AGENTS.md)和[资源打包设计](README.md)。

## 职责归属

- [Assets.xcassets](Assets.xcassets/README.md)拥有 App 图标的资产目录及构建引用。
- [PrivacyInfo.xcprivacy](PrivacyInfo.xcprivacy)保存 App 层实际使用的隐私声明。
- Agent、Skill、Action 翻译和制品目录放在拥有并解释资源的模块。禁止将功能资源复制到 App 公共目录。

## 开发边界

- 修改资产时核对 Xcode 选择的资产名称、目标尺寸、引用及实际打包路径。遵循已有资产来源和许可证要求。
- 修改隐私声明先核对使用该系统能力的代码和实际配置。只声明实际用到的数据或 API 类别。禁止在资源目录保存模型权重、密钥、签名设置、用户媒体及测试结果。
- 保持打包入口显式。开发说明、示例和历史材料留在源码或 docs，禁止加入产品资源清单。

## 示例

更换 App 图标时更新现有 AppIcon 资产及映射，核对 App 实际选中的图标。修改 Agent 图标相关呈现文案时查找实际资源拥有者。使用 [资源校验脚本](../../scripts/README.md#resourcesapp-构建资源)核对相关最终包资源。
