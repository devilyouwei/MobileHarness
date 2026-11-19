# Speech playback tests

[SpeechPlaybackTests.swift](SpeechPlaybackTests.swift) 验证合成与播放独立 FIFO、音频句柄所有权、容量失败、取消加入及失败后的清理。通过实际 Actions SpeechPlayback、AudioCache 和 Assistant 输出适配器运行，PCM 与原生播放端点为显式替身，不代表设备音频验收。源文件仍属于 IntegrationTests。
