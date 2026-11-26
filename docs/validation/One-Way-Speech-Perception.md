# 语音感知单向通信验证

日期：2026-11-26。工作区基线：`ba188b80`。范围见 [需求与设计](../requirements/technical/One-Way-Speech-Perception.md)。

## Swift 回归

- Gateway 集成核对 VAD、ASR 和关键词的独立频道。Assistant 只订阅 ASR 终稿。SpeechPerception 可以在没有 Assistant 状态输入的原生采集上报告关键词。
- Assistant 输入替身覆盖空闲、未知标签、旧回复命中、同一命中重复、终稿先到、关键词先到和终稿在清理中到达。确认接纳的快停只触发一次取消，同轮终稿不再发出打断 Decision 请求。后续语音与已有文本一起进入下一次回复。
- VAD 流程覆盖 63 窗到 64 窗、最后窗口起声、同一句继续说、第二句起声、空或失败终稿、采集代切换和清理未获确认。原生播放快照的时间用例区分实际播放与 200 ms 尾部，并按 PCM 采集时刻验证。
- 聆听用例覆盖旧状态迁移、选用同一 Decision、精确短语与语义唤醒、唤醒句单次入队和失败保留安静状态。

所有以上模型和麦克风输入来自确定性替身。此项未运行真实 Zipformer、真实 ASR、原生 UI 验收或 iPhone 录音与打断。

Swift 专项通过 41 项集成目标测试，涵盖冷启动 PCM 连续性与空转写结算。ModelKit 队列计数测试及匹配到的其余测试目标也通过。独立串行运行时阶段在加入 ASR 事件计数前通过 232 项。

最终普通阶段的 1,273 项集成目标测试中，语音、唤醒、冷启动 PCM 连续性和第 64 窗仍有转写事件待处理的确定性回归通过。普通阶段仍有 4 条失败，来自两个 Action 取消用例的执行状态断言，以及 Tool 往返用例的两种返回路径抛出的取消错误。

## 构建与静态检查

- `./scripts/build-ios.sh` 的五个 Simulator scheme 通过。最终 App 另行重建并通过 Agent／Skill、Live Activity 和中英本地化资源校验。
- `./scripts/check.sh` 在仓库边界阶段退出。基线上的 State Value codec 缺失与 15 项 Xcode 本地化资源归属问题仍存在。
- 单独执行的 Python 工程工具回归通过 8 项，工程和各 plist 校验通过。变更的 Swift 文件通过严格格式和补丁空白检查。全仓格式检查在未改动的 `PromptTemplateTests.swift` 报告 3 个超长行。

## 固定接纳边界与关键词资源

- 第 65 窗及以后的起声使用普通队列。专项回归覆盖窗外终稿先于其 VAD 起声回报、在旧 Action 清理完成前到达，以及在清理完成后到达。三种情况下都与保留的输入分批。
- 关键词资源回归核对 Assistant 标签属于 Zipformer 词表，并验证生产关键词探测、设置诊断、匹配词条和词表校验。语音及通信专项的 IntegrationTests 目标通过 24 项。
- 总 README 与角色模块的文档路径和流程图代码框通过静态检查。App 模拟器制品的 94 个 Agent／Skill 资源通过名称集合和源字节校验，包含两份关键词资源。
- `./scripts/check.sh` 仍在既有 State Value codec 和 Xcode 本地化资源归属检查处退出。本次没有真机声学或真实模型效果验收。
- 五个 iOS 模拟器 scheme 均通过。普通 Swift 全量的 IntegrationTests 目标报告 14 条失败。停词 Decision 与全双工清理用例串行复跑通过，Action 取消和 Tool 往返失败仍见全量记录。
- The idle-input regression passes for typed input and for ASR final after an idle keyword match. The ASR case starts a reply without a Decision request, a post-interruption buffer, or a VAD progress event.

## 2026-11-26 真机安装

签名的 MobileHarness 0.1.0（2026112604）通过严格签名、94 项 Agent／Skill 资源、Live Activity 与双语资源检查。已原位覆盖安装到 iPhone 17 Pro，安装回执序列为 8144，独立设备应用清单确认该构建号。系统因锁屏拒绝启动请求。此记录覆盖构建和安装，真机语音交互仍待验收。
