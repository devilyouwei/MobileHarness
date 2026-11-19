# Actions tests

## 资源和历史约束

参数容错回归覆盖 XML 未声明属性过滤、无参查询、必填缺失/拼写错误和原始容量拒绝、Tool/固定调用严格授权；设备回归验证 disconnect 附带 id/value/action 仍执行且不向端口透传，适用参数非法值仍失败。模型输出与设备端点使用合成替身，不代表真实 BLE 或物理机械臂验收。

生产 Skill 均由显式 Catalog 加载；模型函数绑定由 Skill 选择，真实参数来自 @Action。请求快照、旧原文及内部关联不被后来的加载或投影改写。Schema、revision、媒体和业务 ID 的断言应取实际资源/提交结果，不用已失效的文档示例代替权限。

模型文字、PCM、图片和执行结果替身必须标明合成。保存/捕获次数、错误后不重放、等待用户、原生配对与持久化失败都应断言真实边界。生产资源当前没有 Skill 依赖，现有资产不能冒充共享/循环依赖图的验收。

## 文件归属

- [Camera](Camera/README.md)：所属子能力的测试与资源。
- [Contracts](Contracts/README.md)：所属子能力的测试与资源。
- [Execution](Execution/README.md)：所属子能力的测试与资源。
- [History](History/README.md)：所属子能力的测试与资源。
- [NexArm](NexArm/README.md)：所属子能力的测试与资源。
- [Support](Support/README.md)：所属子能力的测试与资源。
- [System](System/README.md)：所属子能力的测试与资源。
- [UI](UI/README.md)：所属子能力的测试与资源。

- [Speech](Speech/README.md)：播放与音频句柄生命周期。
