# MOSS-TTS-Nano tests

Purpose: validate input selection, bounded PCM conversion and managed local synthesis. Design goals: meaningful deterministic checks plus explicit opt-in real-model evidence.

Tests cover mixed-language voice selection, text/locale rejection, stereo downmix, frame sizing/timing, invalid PCM and total-duration overflow, tokenizer normalization, missing-resource errors and no fallback. `HARNESS_TEST_MOSS=1` adds tokenizer parity, real Chinese/English/mixed speech, finite non-silent PCM, busy rejection, cancellation, unload/reload and shutdown checks.

Startup/diagnostics 在对话接纳和计时测试前执行真实内存合成 warmup，使用合成中文文本并消费 PCM，不播放声音。lazy-kernel 编译失败显式传播；warmup 不改变 StorageCache 的生命周期契约。


## 文件归属

- [MossNanoTests.swift](MossNanoTests.swift)

## 测试分层与可用性

输入/tokenizer/PCM 规则属于 Unit Tests；缺失资源和真实合成的 provider 生命周期属于 Integration Tests。普通平台限制使用 @available，HARNESS_TEST_MOSS 已开启但系统不支持时明确失败。
