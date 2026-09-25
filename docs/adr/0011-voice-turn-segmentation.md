# ADR 0011 有界长句识别与结束语义

状态：已实施。参考 hugging-mac/live_transcription 的状态机和队列策略，保留 Swift 能力边界。

VoiceSegment 用 silence / maximumDuration / inputFinished 表达结束原因。SpeechBoundaryPolicy 保留句内静音、裁剪句尾至约 192 ms；12 秒只是模型输入分段，保持 VAD 递归状态与采样连续性，不提前回复。VoiceInputSession 位于 Gateway/Request，以 actor 管理最多 4 个等待分段、60 秒整轮及 64 KiB 合并文本；超限显式失败。

RequestGateway 新增 recognize，仅返回单段识别文本，不分发 Agent；原 recognizeAndSubmit 兼容入口保留。App 在确认用户结束后调用会话 finish 并经 RequestGateway.submit 提交一次。模型能力接口不变、ModelKit 不依赖本编排。每个段仍受 13 秒输入和 20 秒推理期限约束。

结束并提交：停止采集、排空已接受音频、完成最后一轮识别和回复后结束。取消或系统中断：取消任务、丢弃结果、等待旧模型会话释放；新 generation 不接收旧结果。音频回调不阻塞等待模型，保留有界溢出报错。语音仍半双工，长句内部的模型分段识别除外。

日志记录会话、结束原因、分段推理时间和队列长度，不记录音频和转写内容。保留 AVAudioConverter，不引入线性重采样、降噪模型、WebSocket 或模型名称路由。当前没有重叠解码与跨段文字纠错；不能声称长句分段后准确率无损。
