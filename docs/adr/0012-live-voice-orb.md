# ADR 0012：实时语音预览与圆环交互

> Historical scope: Historical visual and voice stage. The circular UI was replaced by procedural eyes and frequency-based spectra; see [ADR 0045](0045-audio-spectrum-telemetry.md) and [ADR 0046](0046-semantic-eye-expressions.md).

日期：2026-09-24。状态：已实现；真机连续语音与性能验收待完成。

## 决策

页面仅提供一个整圆点击开关与当前字幕。AppLifecycleCoordinator 在 MainActor 发布 idle、loading、listening、processing、speaking、failed 状态，负责设备和生命周期；SwiftUI 不直接访问模型或网关。首次开启加载预热，成功后复用。再次点击立即取消，包含加载和播放阶段。

Gateway 的 VoiceActivitySegmenter 同时产生已提交 PCM 事件与封段结果。确认起音后提交前导及新语音，短暂停顿暂存后恢复提交；端点仅提交保留尾音。maximumDuration 关闭模型输入段但不结束用户一轮。不得重复提交前导、暂存或边界帧。finishStreaming 只排空尚未提交的原始 PCM。

LiveSpeechInput actor 通过 RequestGateway 获取 SpeechRecognitionSession，持续送入 PCM，并发消费 capability 事件。按 segmentID 保持顺序、revision 拒绝旧版本，final 后不允许修订该段；partial 只用于页面预览，绝不调用 Agent。每个模型段结束后合并 final，VAD 端点后由 App 经 RequestGateway.submit 提交一次，回复经 ResponseGateway 合成播放。

队列最多 128 项、4 秒 PCM，一轮最多 60 秒、64 KiB 文本。单事件文本 16 KiB，单模型流最多 64 个文本段。队列或文本超限明确失败；结束输入后的完成等待最多 20 秒。取消关闭 admission、取消模型流和读写任务；App 等待旧会话清理后再启动，并用 generation 拒绝旧预览和播放。ModelKit 无新增业务依赖。

Nemotron 的真实 partial 支持连续字幕；Audio8 的 final-only 实现仍使用相同 capability，不伪造流式识别。字幕支持后缀修订而非假设模型永远只追加字符。UI 最多呈现最近 320 字符；完整 final 不因此截断。

## 动效与限制

加载采用旋转与呼吸，聆听为麦克风 RMS 驱动的蓝色柱纹，朗读为 TTS PCM 包络驱动的紫色波纹。动效使用 Canvas，字幕只对新增或修订后缀淡入。减弱动态效果关闭连续运动，VoiceOver 提供开关与状态语义。

保持半双工：最终识别与播放期间暂停接收新语句，播完尾音保护后继续聆听。固定回复是明确的演示行为，尚未接入 LLM。12 秒模型段可能影响跨段识别质量；实际手机功耗、热状态、自然语音质量和连续对话仍需验收。

## 验证

测试覆盖端点前出现预览且不触发 Agent、旧 revision 不覆盖预览、取消后重建会话，以及流式 PCM 与封段 PCM 完全一致且不重复。保留原长句、尾音、溢出和网关闭环测试。
