# Writer 提示词与续写上下文验证

2026-11-12。范围为 Writer 私有资源、Artifacts 续写接纳值、Writer 模型请求及通信配置。见[变更计划](../requirements/technical/Writer-Resource-Organization.md)。

- Writer 资源目录包含五个提示词文件。三个退役路径未进入最终 App。Writer 的委托、补充、取消、进度和持久终态五条定向契约逐项一致。
- 集成测试覆盖追问回答回到实际请求、作品库与编辑域隔离、结构化 edit 接纳值、长文件和多个有效关联引用。模板回归覆盖八种路径的格式与重试规则。
- 应用工作流测试验证实际文件路径决定格式，指令里的路径样式和模板标记按字面保留，选区、相邻文本、换行和关联文件进入内容请求。内容失败清理旧流后使用新编辑流。
- `./scripts/check.sh` 退出码 0。IntegrationTests 首阶段 1,146 项、AppWorkflowTests 193 项、LiveRuntimeTests 228 项通过。静态边界、Swift 严格格式、7 项 Python 测试、plist 和 `git diff --check` 通过。NativePresentationTests 日志有前两项通过，缺少相机 Metal 用例和套件的结束记录。
- `./scripts/build-ios.sh` 退出码 0。MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron 和 ModelKitSilero 模拟器目标构建成功，包内 47 项 Agent 和 Skill 资源及 Live Activity 校验通过。

模型请求测试使用受控模型。真实模型、原生界面和真机属于独立验收。本机日志为 `/tmp/mh-writer-resource-check.log` 和 `/tmp/mh-writer-resource-ios.log`。

## 2026-11-12 真机安装

使用当前工作区与现有签名配置构建 MobileHarness Debug iPhoneOS `0.1.0 (2026111203)`。深层严格签名、包内 47 项 Agent 和 Skill 资源及 Live Activity 校验通过。已覆盖安装到 Youwei’s iPhone 17 Pro，设备应用清单确认新构建号，安装序号为 6752，系统返回启动成功。此次验证覆盖构建、安装和启动。

本机证据为 `/tmp/mh-writer-device-build.log`、`/tmp/mh-writer-device-signature.log` 和 `/tmp/mh-writer-device-{before,install,version,launch}.json`。
