# Writer 持续后台执行

## 目标与责任

为用户从前台发起的 Writer 执行段接入 iOS BGContinuedProcessingTask。系统批准后继续使用既有 Writer 循环处理网络推理、草稿、工具结果和终态提交。正常隐藏场景继续只调整呈现。后台工作和网络的实际可用性由 iOS 和 Provider 决定。

- App/Lifecycle 的系统适配持有唯一在途请求和已交付任务，使用应用标识符下的通配配置和每段唯一身份，在前台以 fail 策略提交。配置或系统拒绝通过既有 Writer 诊断记录，前台创作可以继续。已经结束的请求不接纳迟到的系统回调，系统取消或过期通过身份围栏返回 Writer。
- App/Composition 将中立执行端口注入 WriterContainer，根替换复用同一系统适配。Config 声明允许的任务标识。初版使用默认 CPU/网络额度；本地 GPU 后台能力需单独签名与真机验证。
- Agents/Writer 在明确委托或回答追问开始执行时提交，按已完成的真实回合报告进度，发布及持久终态后释放。等待用户时结束当前额度。系统过期停止当前模型和文件流，加入清理，保留草稿并记录中断；已进入发布或已开始终态清理时保护实际结果。普通场景变化不提交第二个后台请求。

## 验证

- Writer 15 个参数化场景通过。使用注入的系统执行时间替身，覆盖场景隐藏后完成、等待释放与补充重新申请、迟到回调隔离，以及系统过期中断后保留已写草稿。首轮测试编译发现夹具从错误的记录对象读取工作区标识，改为通过任务记录读取后复跑通过。
- `scripts/check.sh` 退出 0，主集成 1107 项及 LiveRuntimeTests 228 项通过。原生展示套件在相机 Metal 用例开始后缺完成记录。
- `scripts/build-ios.sh` 退出 0，四个模拟器方案、Agent/Skill 与 Live Activity 资源校验通过。最终 App plist 的 `BGTaskSchedulerPermittedIdentifiers` 包含真实 bundle ID 对应的 Writer 通配标识。
- 验证覆盖构建、业务链路和模拟的系统过期。真机锁屏、系统实际授权与 Provider 网络续跑单独验收。
