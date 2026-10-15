# MOSS-TTS-Nano tests

Purpose: validate input selection, bounded PCM conversion and managed local synthesis. Design goals: meaningful deterministic checks plus explicit opt-in real-model evidence.

Tests cover mixed-language voice selection, text/locale rejection, stereo downmix, frame sizing/timing, invalid PCM and total-duration overflow, tokenizer normalization, missing-resource errors and no fallback. `HARNESS_TEST_MOSS=1` adds tokenizer parity, real Chinese/English/mixed speech, finite non-silent PCM, busy rejection, cancellation, unload/reload and shutdown checks.

Startup/diagnostics 在对话接纳和计时测试前执行真实内存合成 warmup，使用合成中文文本并消费 PCM，不播放声音。lazy-kernel 编译失败显式传播；warmup 不改变 StorageAudio 的生命周期契约。

## 待实现

- Mac synthesis does not validate iPhone latency, memory pressure, Chinese pronunciation or sustained stability. No runtime download occurs in tests; provision with scripts/download-moss-tts-nano.py first.

- Warmup does not prove sustained runtime stability.
