# 首次 Welcome 云端服务配置

2026-11-08。未设置云端 LLM Provider 时弹出 Welcome，填写可选 URL（空值使用 OpenAI）和 API key，支持直接粘贴。

## 设计与实施范围

- UI/Root/ApplicationRootView 在应用准备完成、现有设置恢复成功后判断 Provider 列表；已有 Provider（包括未选为当前模型的 Provider）不弹窗。读取失败保留错误和重试，不当作空配置覆盖。诊断启动不展示 Welcome。
- UI/Settings 增加 Welcome 表单，URL 与安全密钥字段都提供系统 PasteButton；密钥不回显、不自动读取剪贴板。URL 复用现有 ProviderEditorDraft 校验和 OpenAI 默认地址，Key 必填且保留现有长度上限。
- SettingsFormController 增加首次配置提交接口：使用既有 SettingsOperating.save 事务保存独立 Provider；提交成功后才更新表单的 Provider 列表。一次只接纳一个保存，失败保持草稿并允许重试。不复制凭据存储或网络实现。
- Welcome 只创建服务配置；保存后进入已有“智能体大脑”页面，由用户分别选择 Assistant/Writer 的 Provider 和模型。自定义 OpenAI 兼容服务不预设模型 ID；已有角色选择保持不变。允许“稍后设置”，本次根页面不再提示，下次启动仍按已保存 Provider 判断。
- UI 根只组合弹窗和导航；Actions/System/Provider 继续拥有请求、Keychain/配置保存与模型应用，接口链路仍是 UI → ApplicationControl → Gateway → Actions。未新增目录、数据库表或第三方依赖。
- 同步 UI/Root、UI/Settings、UI、Actions/System/Provider 与总体 README 的实际交互和边界；Tests/AppWorkflowTests 在现有设置交互测试中覆盖首次判断、恢复失败、默认/自定义 URL、空 Key、失败重试、并发保存、保存后重新恢复与既有 Provider 不覆盖。

## 验证

执行设置专项测试、./scripts/check.sh 和 ./scripts/build-ios.sh。自动化替身验证不代表真实凭据、云端网络或真机系统粘贴授权验收；在验证记录中明确范围。

## Writer 独立选择的保存修正

Welcome 创建 Provider 后 Assistant 保持本地，其草稿 URL 仍可能等于新 Provider 的默认 URL。现有 SettingsFormController.save 无条件把该 URL 对应 Provider 的 key/model 替换成 Assistant 草稿值，会在仅选择 Writer 时用空密钥覆盖新服务。调整为只有 Assistant 已启用云端时才同步其选中 Provider 的 key/model；增加 Welcome → 仅选择 Writer → 保存 → 恢复的端到端表单回归，保留 Provider 的凭据与 Writer 独立选择。同步 Settings README 的实际保存规则。

## 交付记录

Welcome、既有保存链路接入、独立 Writer 凭据修正、回归测试及当前设计文档均已完成。专项测试与最终四项 iOS 构建通过；全量检查的一项既有跟踪测试间歇失败、独立复测结果和原生验收边界见[验证记录](../validation/Welcome-Provider-Setup.md)。
