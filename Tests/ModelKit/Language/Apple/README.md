# Apple tests

模型能力与适配中本目录能力的测试。测试通过真实接口及显式替身验证可观察行为、失败、取消和清理；真实模型及设备用例保留显式 gate。

## 文件归属

- [AppleChatTests.swift](AppleChatTests.swift)

AppleChatTests cover public text-only capability flags and pre-inference rejection, native transcript roles/text, unsupported tools/images/history, empty current input, Unicode snapshot conversion, duplicate snapshots, revisions and output bounds. They import the standalone Apple provider and require no live model.
