# Default assembly tests

## Ownership and coverage

默认装配测试验证 App 管理的 ModelContainer，不取得进程单例或直接注册生产模型。覆盖根／四子能力隔离、缺失资源目录时无副作用启动、暂停与恢复、重复停止、旧端口拒绝，以及保留的聊天端口随配置变化切换且不影响另一根。

模型工厂只建立轻量对象；默认测试不运行真实推理、不初始化 GPU 权重、不请求设备权限、不发送网络请求。资源取消加入／权重保留与不合作加载在 ModelKitRuntimeTests 覆盖；App 缓存一致性在 IntegrationTests 覆盖。构建与真机验收独立记录。


模型根停止后start／setForeground的错误断言使用ModelFailure；底层能力端口仍验证原始InferenceAdmissionError，明确根与领域接口边界。

Preparation-step tests cover requested-order deduplication, registered-but-not-ready status and explicit rejection after root shutdown, without loading models.

ChatExecutionTests exercises root-owned local FIFO (one active/eight pending), overflow, immediate cancellation slot reuse, native cleanup joining, failure advancement and retained completed handles, using an explicit fake Chat provider. Immutable cloud selections/configuration reuse and root retirement are checked without HTTP. Provider HTTP concurrency is tested in OpenAIChatTests.

D3NativeTests is explicitly opt-in via D3_TEST_RESOURCES or D3_EDGE_TEST_RESOURCES. It performs real Swift tokenizer/Core AI inference against a locally supplied published fixture, checks short-input selection and oversized-input completion. DecisionAdapterNativeTests checks D3 token truncation and graph input layout without weights. Ordinary default tests remain artifact-free; native results are recorded separately in docs/validation.


Default local Gemma and cloud capabilities both advertise tools. Configuration isolation uses their distinct image support; a fixed local ChatModel retains local tool/image capabilities after the default selection changes. Queries remain artifact-free and do not issue HTTP requests.

## 文件归属

- [ChatExecutionTests.swift](ChatExecutionTests.swift)
- [D3NativeTests.swift](D3NativeTests.swift)
- [DefaultsTests.swift](DefaultsTests.swift)
- [SpeechSelectionTests.swift](SpeechSelectionTests.swift)

适配器与 tokenizer 一致性由 [DecisionAdapterNativeTests.swift](DecisionAdapterNativeTests.swift) 验证；D3 的业务 case 评估归 [experiments/decision](../../../../experiments/decision/README.md)，原生制品与超长输入验收保留在本目录。

## 原生一致性检查

DecisionAdapterNativeTests 每模型最多3条参考请求；tokenizer 夹具验证编码，不发模型请求。工程夹具由本目录独立维护，制品路径相对根 Models，不读取实验输入或结果。

- [app_binary_parity.py](../../../../scripts/models/app_binary_parity.py)：最多3条 Swift/Python Vela 数值检查，显式 --models/--input/--output。
- [laya_parity.py](../../../../scripts/models/laya_parity.py)：3条发布参考的 token/marker/概率检查，显式 --output。
- [vela31_parity.py](../../../../scripts/models/vela31_parity.py)：3条发布参考的加载器检查，显式 --reference/--output。

这些脚本拥有独立的工程参考适配器，不导入 experiments；一致性断言与夹具由工程侧维护。历史全量测量不作为当前默认工程测试规模。

## 测试分层与输入有效性

DefaultsTests、ChatExecutionTests、SpeechSelectionTests 验证真实默认根/子能力、FIFO 及 SpeechSelection/ModelManager 的注册与选择协作，属于 Integration Tests；不加载真实权重。平台受限的普通回归使用 @available 报告跳过；显式开启的 D3/Apple 模型 smoke 在平台不支持时抛 unavailable。

[DecisionAdapterNativeTests.swift](DecisionAdapterNativeTests.swift) 包含两层：decisionParityRequiresSelectedReferenceCases / tokenizerParityRequiresReferenceRows 是 Unit Tests，仅使用内存夹具；两个 native parity 用例是显式启用的 Integration Tests。原生加载前拒绝未知模型、空参考集、所选模型缺失、非法输出种类及空 tokenizer rows；每模型最多三个请求不变。
