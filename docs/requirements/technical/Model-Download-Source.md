# 模型下载源交互

## 需求与实施计划

Agent Brains 与 speech 资源页面共用即时选择的下载源，移除独立 Save download settings 按钮及废弃文案。沿用下载前保存当前源及根拥有的防抖持久化，下载接纳时捕获源；切换只影响后续下载，不改变在途任务。

ModelResourcePreferencesService 在无持久偏好时读取系统首选语言：zh（含简繁体）使用 https://hf-mirror.com，英文及其他语言使用 https://huggingface.co。已保存的用户选择优先，不因语言变化覆盖。系统语言作为可注入闭包用于测试，不依赖 UI 的 App Language 设置。

涉及 UI/Settings/ModelResourcesView.swift、UI/Shared/Localizable.xcstrings、Actions/System/ModelResources/ModelResourcePreferencesService.swift；同步 Settings 与 ModelResources README。模块边界与跨模块流程不变。补充默认语言、保留已有偏好及在途下载源隔离测试，执行 scripts/check.sh 和 scripts/build-ios.sh；原生 UI 与实际网络下载另行验收。

## 实施结果

代码、文案清理与 owning README 已同步；新增回归用例通过，iOS 四目标构建通过。完整测试存在范围外失败及停滞，详见[验证记录](../../validation/Model-Download-Source.md)。原生页面与真实下载尚未验收。

## 下载源名称简化

所有页面的下载源显示名称统一为 Hugging Face，移除英文 Official 和中文“官方”修饰；更新共享资源页面、字符串目录和相关下载源说明。内部源标识、地址与下载行为不变。
