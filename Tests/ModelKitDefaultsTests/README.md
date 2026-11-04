# Default assembly tests

## Ownership and coverage

默认装配测试验证 App 管理的 ModelContainer，不取得进程单例或直接注册生产模型。覆盖根／四子能力隔离、缺失资源目录时无副作用启动、暂停与恢复、重复停止、旧端口拒绝，以及保留的聊天端口随配置变化切换且不影响另一根。

模型工厂只建立轻量对象；测试不运行真实推理、不初始化 GPU 权重、不请求设备权限、不发送网络请求。资源取消加入／权重保留与不合作加载在 ModelKitRuntimeTests 覆盖；App 缓存一致性在 IntegrationTests 覆盖。构建与真机验收独立记录。


✅ 模型根停止后start／setForeground的错误断言使用ModelFailure；底层能力端口仍验证原始InferenceAdmissionError，明确根与领域接口边界。

Preparation-step tests cover requested-order deduplication, registered-but-not-ready status and explicit rejection after root shutdown, without loading models.

ChatExecutionTests exercises root-owned local FIFO (one active/eight pending), overflow, immediate cancellation slot reuse, native cleanup joining, failure advancement and retained completed handles, using an explicit fake Chat provider. Immutable cloud selections/configuration reuse and root retirement are checked without HTTP. Provider HTTP concurrency is tested in OpenAIChatTests.
