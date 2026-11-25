# ModelKit 模型目录与请求元数据

ModelKit 为 Chat 与 Decision 提供可选模型目录和实际请求的身份、可用统计。选模、绑定和记录共享稳定模型 ID。Assistant、Writer、标题摘要和 Decision 读取 SDK 事实。语音、视觉保留现有接口。

- ModelKit Support/Management 复用注册、制品和系统可用性，ModelLanguageProviding 投影可选模型。设置业务拥有角色能力筛选与提交，UI 消费独立的展示值。沿用已保存 ID，Writer 旧本地选择解析为原有 Gemma。不可用选择显式报告。
- Support/Core 在请求会话提供只读元数据，Language 适配器沿实际发出边界记录身份，并复用输出、用量、结束原因和计时的采集。排队与 Chat Decision 透传同一次请求的事实。发出前取消无历史请求，已发请求失败仍保留已采集的事实。缺失字段为空。
- Agents 按实际请求记录 ModelKit 元数据，Actions 投影设置与历史，Storage 沿现有 generation_meta_json 保存并兼容旧标签和清理行为。UI 历史不查询当前配置。
- 实现后对齐总体设计及 ModelKit、Agents、Actions、Storage 和 UI 拥有目录设计。验证使用 Swift 回归、工程检查及 iOS 构建，Apple Intelligence 真机验收单列。

验收步骤和执行结果见[验证记录](../../validation/ModelKit-Model-Identity.md)。
