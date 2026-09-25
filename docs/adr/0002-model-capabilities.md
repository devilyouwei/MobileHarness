# ADR 0002 模型能力与后端解耦

状态：采纳设计，待实施。日期：2026-09-22。

P1 优先接入必备模型与能力封装。保留原方案 ModelKit 的 Core、Speech、Language、Vision、Embedding、Runtime 分组，增加制品管理、统一 IO 和模型专用适配层。详见 [ModelKit README](../../MobileHarness/ModelKit/README.md)。

区分能力、具体模型、推理后端与模型制品。Agent 只依赖类型化能力协议，由 App 注册与绑定模型；生命周期由 ModelManager 管理，多模型竞争由 InferenceScheduler 管理。每次推理独立会话与取消范围，避免共享 provider 的全局取消误伤其他 Agent。

首次实现后端时，核心 ModelKit 与具体 SDK adapter 拆为独立 target；当前目录设计仅代表逻辑组织，不代表已有编译隔离。当前未使用的 ModelKit → AgentCore 依赖届时移除，禁止形成反向依赖环。

P1 必需能力为 ASR、TTS、一个本地 LLM 与 JEV；系统语音 provider 和自有权重采用不同资源所有权语义，JEV 可复用 LLM。选定一个后端先验证真实闭环，其他后端按需求扩展。Core AI 已有公开框架，具体设备和系统支持仍按集成版本验证。

完整 Runtime 增强移至 P2；P1 只同步实现取消、会话关联、流消费和最小调度等模型接入前提。保持原 Word 文档不变，在仓库设计文档中记录实施顺序调整。
