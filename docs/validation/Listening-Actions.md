# BasicSkill 聆听控制验证

日期：2026-11-01。范围：`Speech.Listening.startListening` / `stopListening` 与 BasicSkill 绑定；窗口化、相机增强、录像、灵动岛不在本次范围。

## 自动化覆盖

- ActionAuthoringTests：两个入口拒绝所有参数，失败及预执行取消传播，启停分别传递明确 true/false。
- BehaviorAssemblyTests：BasicSkill 的 canonical path、别名和 ListeningControl Channel；缺少能力时失败；执行端点拒绝错误根会话、未绑定和已解绑 owner。
- VoiceTests：非运行态与错误会话拒绝，关闭幂等，回复占用释放后仍保持关闭，原 UI 明确启用可恢复，paused 期间拒绝打开但允许关闭；直接控制不会递归排队另一 Action。
- 提示词预算及全量资源目录校验沿用现有阈值。

## 运行记录

首轮 check.sh 发现新增 Channel 的旧断言、提示词超预算及具体 actor 同步方法与默认异步协议方法的重载选择问题。对应修正为更新预期 Channel、压缩教学/声明、明确异步签名，未提高提示词预算阈值。

最终验证结果：

- `./scripts/check.sh`：退出码 0。模块边界、6 项下载脚本测试、Swift 格式 lint、全部 Swift 测试及项目 plist 校验通过。通用 IntegrationTests 为 931 项；独立原生运行时阶段为 225 项（约 206 秒），其余目标的测试亦通过。
- `./scripts/build-ios.sh`：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个未签名模拟器构建均通过。
- 最后一次文案及状态显示收敛后，另以同样配置重建 MobileHarnessSimulator 并执行 `verify-app-agent-resources.py`，应用构建及 25 项包内资源验证通过。
- 提示词专项回归通过，最终基础提示词为 24,602 UTF-8 字节，加载 Photography 后为 31,978 字节；保持原 25,000 / 32,000 阈值，并保留已有 Task 授权及自动语音规则。
- `git diff --check` 与变更 Markdown 本地链接核对通过。构建仍有既有警告；未将警告解释为失败或真实设备验收。

运行日志位于本机 `/tmp/mobileharness-listening-check-passed.log`、`/tmp/mobileharness-listening-build-final.log`、`/tmp/mobileharness-listening-app-verified.log` 与 `/tmp/mobileharness-listening-focused.log`。这些临时路径不是持久化附件；本报告保存结果及证据范围。

## 真机与真实模型验收（未执行）

1. 长按开始，分别说“结束聆听”“结束对话”“先聊到这里”；记录真实模型输出为 stopListening，而非仅口头答应。
2. 确认聆听指示、麦克风采集与声音输入停止；等待回复结束、切换页面后均不重开。退出 Action 后不追加语音。
3. 再次长按，确认权限、唤醒反馈和连续对话恢复；从文字输入明确要求打开聆听时验证 startListening。
4. 覆盖已有业务 Task、回复/播放与关闭并发、后台切换、音频中断及权限拒绝；记录实际提供者、资源版本、设备/iOS/音频路由与失败。

上述自动化使用受控模型/设备替身，构建结果不代表真实模型理解、原生 UI 或物理麦克风验收。

## 真机安装（2026-11-01）

按用户要求，使用现有本地签名配置对当前工作区执行 MobileHarness / Debug iPhoneOS 构建，构建号通过命令行指定为 `2026110101`，未改仓库签名配置。设备构建、严格深层签名及 25 项最终 Agent/Skill 资源校验通过。

已原位安装至连接中的 Youwei’s iPhone 17 Pro（dev.mobileharness.app），devicectl 安装成功，databaseSequenceNumber 为 5164。独立应用清单确认版本 0.1.0 / build 2026110101；系统启动请求成功。未卸载或清空应用数据。安装与系统启动不代表语音退出意图、原生 UI 或麦克风实际启停验收通过，上述真机功能验收仍未执行。

本机临时日志：`/tmp/mobileharness-listening-device-build.log`、`/tmp/mobileharness-listening-device-install.json`、`/tmp/mobileharness-listening-device-installed.json`、`/tmp/mobileharness-listening-device-launch.json`。
