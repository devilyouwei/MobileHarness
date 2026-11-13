# Assistant 执行轮次结算验证

2026-11-12。关联[变更计划](../requirements/technical/Assistant-Channel-Settlement.md)。

真机只读 SQLite 核对发现，首个相机轮次的两个调用分别以 lensNotOwned 结束。约 2.5 毫秒内的两个回执分别成为 assistant_messages 743 和 744，并各有一条完成的模型请求。随后一次成功切镜与一次成功拍照也分别触发独立请求。回归使用受控模型和执行端点再现该时序。

- 定向 Swift 回归 8 项通过，包含成功和失败 Action 合批、执行期间缓冲用户输入、原生 Tool 配对、打断和暂停清理、执行封口失败和队列容量。
- `./scripts/check.sh` 退出码 1。并发集成阶段有三个 ContainerFailureTests 的诊断展示用例及一个 NexArmAimTests 的跟随目标用例失败，四项串行复跑均通过。变更回归、193 项 AppWorkflowTests、228 项 LiveRuntimeTests、静态边界、格式、Python 和 plist 检查通过。NativePresentationTests 有单项通过记录，缺少整套结束记录。
- `./scripts/build-ios.sh` 退出码 0。四个 iOS 模拟器构建目标和包内 47 项资源、Live Activity 校验通过。 `git diff --check` 通过。
- SQLite 排查使用旧真机版本。修复版的真机语音与相机交互需要独立验收。

本机验证日志为 `/tmp/mh-channel-settlement-{focused,check,serial,ios}.log`。

## 2026-11-13 真机安装

使用现有签名配置从当前工作区构建 MobileHarness Debug iPhoneOS `0.1.0 (2026111301)`。深层严格签名、包内 47 项 Agent 和 Skill 资源及 Live Activity 校验通过。已覆盖安装到 Youwei’s iPhone 17 Pro，安装序号为 6828。设备应用清单确认新构建号，系统返回启动成功。真机 ReACT 合批交互仍待验收。

本机证据为 `/tmp/mh-channel-settlement-device-build.log`、`/tmp/mh-channel-settlement-device-signature.log` 和 `/tmp/mh-channel-settlement-device-{before,install,version,launch}.json`。
