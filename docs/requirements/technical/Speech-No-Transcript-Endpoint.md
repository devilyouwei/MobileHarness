# 空转写的语音端点

持续杂音可能让 VAD 保持说话状态。增加仅用于空转写的端点，在一轮已交给 ASR 的音频达到 64 个 512-sample 等效窗口（2.048 秒），且从未产生非空转写时，由 SpeechPerception 主动结束该轮。

- `SpeechRecognitionTurn` 只计算成功发送给识别会话的采样。非空转写停用本轮的空转写端点。主动收尾最多等待 500 ms，再取消并加入旧识别会话。只保留识别器确认的终稿。
- `SpeechPerceptionAgent` 在逐帧管道中接纳该端点，复用发布终稿或结束空语句的路径。端点同时退出 Zipformer 候选和当前识别轮。已有文字的语句继续由 VAD 收尾。
- `VoiceActivitySegmenter` 重置 VAD 模型和语句状态。`SpeechBoundaryPolicy` 在主动结束后要求连续 160 ms 低于基础 VAD 阈值，再重新接纳起声，阻止持续杂音反复开启空轮。
- 用 Swift 回归验证已发送窗口、空白转写、终稿收尾、持续杂音的重起声限制和正常端点。同步 SpeechPerception 的实现说明和验证记录。
