# ADR 0019 · Agent 独立 plist 配置与统一开发规范

> Configuration migration: [ADR 0061](0061-agent-json-v5.md) supersedes the JSON schema, hidden/text alias and all-in-JSON registration portions of this historical decision. Its other runtime contracts remain unchanged.

> Historical scope: Historical plist v1 format. [ADR 0022](0022-json-capability-configuration.md) replaced it with JSON, and current production declarations use JSON v4; see the [Agents README](../../MobileHarness/Agents/README.md).

日期：2026-09-24。状态：采用。

## 决策与格式

每个业务 Agent 的能力声明迁至其目录内 `<AgentName>.agent.plist`，采用 UTF-8 XML Property List 和 schemaVersion=1。统一字段规范、完整示例、目录/依赖/生命周期/并发/双输出协议/取消/测试与交付规则集中在 MobileHarness/Agents/README.md，不在各 Agent 再维护不同标准。

配置声明 agentID、actions、tools、channels、textActions。所有字段显式填写；未知/缺失字段、类型错误、非支持版本、重复 alias/数组项、非法参数、超限和无效文本映射明确拒绝。允许工具型 Agent 的空 textActions，Assistant 另要求非空且 agentID 匹配。

AgentCore/Capability/AgentConfiguration 负责数据校验，不依赖 Bundle 或 Agents；Agents/AgentConfigurations 负责 Bundle.module 中的有界资源读取。SwiftPM process 打包独立资源，无源码路径 fallback。配置加载后是实例内不可变快照，不热更新。

## 业务兼容与边界

Assistant 默认 say/print/smile、runtimeInfo、Speech/Display/main Channel 保持不变；两条文本动作的顺序也来自配置。Descriptor、模型上下文、解析器与输出校验使用同一注册快照。

Assistant 初始化变为 throws，可注入经过同一校验器验证的配置；App 捕获错误显示未就绪，不强制解包或回退硬编码能力。业务命令 /smile、/status 可以引用固定 alias，但删除能力后必须报告运行错误，不崩溃。

Agent 配置定义“可使用的能力”，App 的 ActionRegistry/ToolRegistry 仍在 Swift 中显式注册“已实现的 handler”。配置不能生成代码、反射任意函数或替代平台权限。未注册真实实现的路径在分发时明确失败；完整启动期跨目录验证、热更新、远程配置和完整 JSON Schema 不在本轮范围。

## 验证

测试覆盖实际打包的 Assistant plist、默认能力、配置变更实际改变 Assistant 输出、实例隔离、命令能力缺失、非法字段/版本/类型/重复/参数/文本映射/身份/容量；继续运行原有语音、解析器、Channel 和取消回归。

验证结果：✅ scripts/check.sh 通过，包含 50 项集成测试与参数化配置拒绝案例；✅ 五个模拟器 scheme 构建和真机目标 Debug 无签名构建通过；✅ 实际模拟器/真机 App 包内 plist 与源码配置一致，工程引用核对通过。❌ 默认跳过的真实模型/音频测试及真机连续语音人工验收本轮未执行。
