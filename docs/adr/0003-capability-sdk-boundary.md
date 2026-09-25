# ADR 0003 能力 SDK 与应用组装的编译边界

状态：已实施。日期：2026-09-22。

ModelKit 独立为零项目内依赖的基础能力 target/product，删除未使用的 AgentCore 依赖及旧 ModelProvider 契约。业务调用方只使用 ChatCapability、SpeechRecognitionCapability、SpeechSynthesisCapability、JudgeCapability，或按需组合为 VoiceCapabilities。

ProviderID、工厂注册、实例缓存与绑定解析进入独立 ModelKitRuntime target/product；只由应用组装层使用。具体模型和后端 SDK 以后进入独立 adapter target，依赖 ModelKit；ModelKit 和 ModelKitRuntime 均不引用 Agent 或其他业务层。

每个调用有独立 session，支持单请求取消和单消费者流。当前采用有界输出加超限失败，不声称已实现生产者等待式背压。ASR 输入顺序与半关闭独立管理，输出 PCM 不接管设备。

相较 ADR 0002 的远期设计，本次落地能力 SDK 与组装边界；权重生命周期、租约、调度和真实模型接入仍未实现。ModelKit README 改为当前目录的技术说明、行为契约与维护规范，远期计划保留在 Roadmap。
