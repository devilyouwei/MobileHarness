# Speech tests

模型能力与适配中本目录能力的测试。测试通过真实接口及显式替身验证可观察行为、失败、取消和清理；真实模型及设备用例保留显式 gate。

## 文件归属

- [ASR](ASR/README.md)：所属子能力的测试与资源。
- [Apple](Apple/README.md)：所属子能力的测试与资源。
- [Enhancement](Enhancement/README.md)：所属子能力的测试与资源。
- [TTS](TTS/README.md)：所属子能力的测试与资源。
- [VAD](VAD/README.md)：所属子能力的测试与资源。
- [ZipformerTests.swift](ZipformerTests.swift) 校验分包与 Kaldi 特征一致性、冷模型不触发加载、独立词和长词的前后缀边界。真实 Core ML 测试通过 `HARNESS_TEST_ZIPFORMER_MODEL` 和 `HARNESS_TEST_ZIPFORMER_WAV` 显式启用，可用 `HARNESS_TEST_ZIPFORMER_LABEL` 指定 `en-stop` 或 `zh-stop`。
