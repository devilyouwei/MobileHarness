# Enhancement tests

模型能力与适配中本目录能力的测试。测试通过真实接口及显式替身验证可观察行为、失败、取消和清理；真实模型及设备用例保留显式 gate。

## 文件归属

- [DeepFilterTests.swift](DeepFilterTests.swift)
- [WindowedEnhancementTests.swift](WindowedEnhancementTests.swift)

## 契约覆盖

DeepFilterTests additionally covers the standalone enhancement DSP roundtrip, malformed auxiliary archives and input validation. Set `DEEPFILTER_MODEL_ROOT` to a provisioned DeepFilterNet3 directory to run real Core ML smoke cases; absence of this variable does not validate real model inference.

WindowedEnhancementTests covers seam gain, exact sample count/timestamps, bounded input, discontinuity rejection, failure/reset and cancellation of in-flight results. SpeechEnhancementWorkflowTests in IntegrationTests verifies that VAD and ASR receive the same processed PCM and that utterance boundaries retain capture-scoped history. Real windowed timing includes DSP and tensor transfer after explicit preload; it is a host smoke measurement, not iPhone acoustic acceptance.
