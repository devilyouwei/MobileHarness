# ModelKitAppleSpeech

Apple 系统 ASR/TTS 的独立 adapter target，只依赖 ModelKit。当前 App 仅使用其中的 TTS，ASR 已切换到 Nemotron；Apple ASR 保留为独立可选 adapter。没有模型权重或第三方依赖，不引用 Agent、Gateway、PlatformKit 或 UI。

- AppleSpeechRecognition：SFSpeechRecognizer，兼容 iOS 18 基线。检查授权、语言和 isAvailable。AppleSpeechRecognitionPolicy 默认 onDeviceOnly，检查 supportsOnDeviceRecognition 并强制 requiresOnDeviceRecognition；allowNetwork 允许 Apple 在线处理，不要求离线资源。每个会话独立 request/task 并固定本次策略，最多 2 个会话，25 秒失败超时。PCM 输入限定 mono Float32；partial/final 使用同一 segmentID 和递增 revision。
- AppleSpeechSynthesis：AVSpeechSynthesizer.write 导出音频，不直接播放。每会话独立合成器，最多 2 个会话；输入上限 2048 UTF-8 字节，30 秒失败超时。系统音频转 mono Float32 后按 16 KiB 分块，输出队列最多 256 块，满载明确失败。
- PCMCodec：复制系统音频缓冲为 Sendable 值，不跨 actor 传递可变 AVAudioPCMBuffer。
- SynthesisPCMAccumulator：将系统频繁返回的小块音频合并为 16 KiB 事件，结束时输出剩余尾块；保持 PCM、序号与时间戳连续，避免短回复因小块数量过多而溢出。

会话终止通过 MainActor 清理系统任务。回调只复制与输出值，框架对象由各自 worker 持有。端侧识别不受支持或资源未就绪时返回不可用原因；不能声称所有设备和中文资源都保证离线可用。

同一 adapter 复用按语言创建的 SFSpeechRecognizer；每句仍使用独立 request/task。正常 final 完成只释放任务引用并取消超时，不再调用系统任务的 cancel；失败与主动取消才中止任务。生命周期日志使用 `dev.mobileharness.speech` subsystem，记录请求标识、活动 worker 数及错误域/代码，不记录录音、识别文本或错误 userInfo。连续对话后偶发初始化错误不能仅凭 code=300 判断设备永久不支持；需结合完整生命周期和系统资源日志定位。

可用性提示分别区分未授权、不支持语言、不支持离线识别和服务暂不可用，不以“请在真机测试”代替具体诊断。应用在可用性检查通过后才启动麦克风，因此该阶段失败不代表麦克风输入故障；也没有按模拟器平台直接禁用语音的分支。

应用负责协调所需权限。Apple ASR 的 onDeviceOnly/allowNetwork 属于可选 adapter 策略，不进入通用能力协议；当前生产识别使用 Nemotron，没有 Apple ASR 联网切换 UI。ModelKit 中的 Apple adapter 消费 PCM 或导出合成 PCM，不拥有麦克风和扬声器。麦克风采集、音频会话、采集格式转换与播放位于 PlatformKit/Audio；Silero 在 ModelKit 中生成 VAD 概率，Gateway 决定语音分段。Speech Action 调用合成能力并通过 App 注入的独立播放服务输出声音。

新系统的 SpeechAnalyzer 可以作为后续同协议 adapter，当前没有实现或伪装该路径。真实麦克风识别与扬声器效果需真机验收，自动测试不弹权限、不使用用户录音。
