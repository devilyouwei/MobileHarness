# ModelKit 模型目录与请求元数据验证

验证日期 2026-11-25。范围见[技术需求](../requirements/technical/ModelKit-Model-Identity.md)。

Swift 回归覆盖目录中的公开身份、角色资格、云端响应型号、部分 token 统计、历史跨请求模型名和兼容读取。Cloud 回归使用本地 URLProtocol 响应，目录和历史用例无需加载真实模型权重。

`./scripts/check.sh` 的架构检查报告 AgentContainer State Value 编解码器规则和 15 个 Xcode 本地化资源分组问题。对提交基线独立运行同一检查，输出一致。独立运行检查脚本自测的 8 项 Python 用例通过。改动的 Swift 文件通过严格格式检查。全量格式检查另外报告既有 PromptTemplateTests 的 3 处超长，在提交基线复现。Xcode 工程 plist、字符串目录 JSON 及 diff 格式校验通过。

## Swift 测试

- OpenAI Chat 的 57 项回归通过，覆盖绑定 ID、服务端报告型号、首输出、完成边界和可缺失的 token 字段。
- 集成组 1,252 项运行时，SQLite 模型身份测试通过。静默唤醒用例在并发运行中一次超时，前一轮全量运行及最终定向复测的两个参数均通过。定向复测同时通过 SQLite 归档身份和 Writer 新模型选择。
- LiveRuntimeTests 与 NativePresentationTests 单独运行，232 项通过。工程测试使用替身或工程夹具，真机验收独立记录。

## iOS 构建

`./scripts/build-ios.sh` 的五个 Simulator scheme 均构建成功。云端会话修正后增量重建主应用成功。应用内的 Agent/Skill、Live Activity 和中英文资源校验通过。宿主 CoreSimulator 比 Xcode 要求的版本旧，通用 Simulator 目标可编译，未运行模拟器交互验收。

## 真机验收

在支持并启用 Apple Intelligence 的设备上，从 Assistant 的 Agent Models 选择本地 Apple 系统模型并保存。发送新请求，在历史详情核对本次请求的公开身份为 `apple-system`，显示名为 Apple 系统模型，输入和输出统计来自系统会话。再切换至已安装的 Gemma，发送一条新请求，分别核对两条详情。对正在生成的请求取消，检查已派发记录保留身份，未报告的统计为空。真实 Apple 推理和原生页面交互尚未在本机验收。
