# Agent 展示调用与反馈所有权验证

日期：2026-11-06。范围为当前工作区的角色展示所有权与模型反馈来源修改；工作区同时存在独立 Writer 生命周期修改，不作为本次交付范围。

## 实现与回归范围

- SpeechPerception、SpeechSynthesis 绑定各自注册的 Gateway consumer，直接调用自己的 Island 工具；覆盖 UI 暂不可用后恢复、聆听暂停/恢复、合成完成与真实播放结束分离、过期播放结束回调、独立停止清理。
- Photographer、ApplicationControl 在已有事实输入中发布自己的相机/连接状态；测试不创建 Assistant，验证倒计时、断连临时展示到期与角色停止。删除集中 IslandDomainPresentation 观察/代发实现及其旧测试。
- Assistant 自己管理等待岛和任务岛。Support 只保留通用发布机制与等待事实回调；字幕、窗口、音效和频谱按现有拥有者执行，频谱走播放器到 UI 的专用数据通道。
- GenerationEvent.runtimeAction 记录自然文本的代码展开来源；显式模型 Action 保持 action。Chat 按单次调用来源隔离结果，包含异常。同一路径同时具有内部权限和模型权限时，内部字幕不触发 ReACT，模型显式字幕的成功/失败仍可反馈续轮；未关联 ToolResult 被拒绝。
- 其余角色静态核对：Writer 自有任务岛/创作流程，Memory 自有 HistoryPresentation，VisionPerception 自有 Gaze/Pose 调用；保留其现有所有权，不新增 Assistant 代发。
- 执行历史仍记录内部结果与失败，内部调用仍可参与完成屏障；不把失败吞掉或伪造成模型结果。

## 检查记录

- 针对性回归首轮：7 项通过，涵盖语音岛、同路径来源隔离、内部字幕成功/失败不续轮及既有 Writer/Assistant 岛。
- 首轮完整检查：边界、格式、Python 6 项与原生阶段 227 项通过；普通阶段 1051 项中记录 76 个问题。原因是旧解析测试只接收 action 事件，以及蓝牙诊断测试装配未注册角色新增的 Island 工具；已分别适配 runtimeAction 和注册实际 IslandModule。此失败记录保留，不改写为通过。
- 最终完整检查：./scripts/check.sh 退出 0；边界检查、Swift 格式、Python 6 项、普通集成阶段 1051 项及其他包测试、原生阶段 227 项、工程/权限 plist 校验全部通过。
- iOS 构建：最终来源传递代码完成后再次运行 ./scripts/build-ios.sh，退出 0；MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个目标均 BUILD SUCCEEDED。
- 静态检查：删除的集中投影类型在当前源码/测试/Xcode 工程中无残留引用；新增 Markdown 本地链接有效；git diff --check 通过。

## 证据限制

自动回归使用模型、识别、合成或设备替身；check.sh 原生测试与 Simulator 编译不等于真实模型、iPhone 灵动岛/字幕/声音的端到端验收。本次未运行真实模型或物理设备 UI 验收，未新增目录、模块或第三方依赖。
