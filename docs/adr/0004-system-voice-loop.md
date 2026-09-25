# ADR 0004 系统语音网关闭环

状态：已实施，真实麦克风/识别效果待真机验收。日期：2026-09-23。

为先验证语音交互，新增 ModelKitAppleSpeech adapter：系统 ASR/TTS 实现已有能力协议。兼容 iOS 18，ASR 使用 SFSpeechRecognizer，adapter 默认强制端侧。2026-09-23 经用户授权，App 显式选择 allowNetwork 用于调试，允许 Apple 在线处理音频；UI 可切回离线，已有请求策略不随配置变化。TTS 使用 AVSpeechSynthesizer.write 导出音频。

RequestGateway 注入识别能力，将 VAD 分段转换为一次 final 文本输入；ResponseGateway 注入合成能力，验证输出与 speak 授权后生成 PCM。App 组装具体实现，PlatformKit 独立负责权限、音频采集、基础能量 VAD 和播放。ModelKit 保持零业务依赖。

首版采用持续采集、轮流处理：识别/回复时不接收新一句，播完恢复。这样先避免扬声器自激循环；没有宣称支持抢话、回声消除或噪声鲁棒 VAD。基础能量阈值可在 UI 调整，未来可换更好的检测器。

每次语音会话以新的 sessionID 隔离，停止/后台/中断/音频路由变化取消所有相关工作。Agent 使用明确标注的固定回复；不连接 LLM。实现边界、预算与验收详见 Voice.md。
