# Agent 展示调用与反馈所有权

## 目标与边界

按角色内聚展示语义和调用生命周期：Agent 自己调用其内部展示 Action/Tool，自己处理结果（包括异常），不委派其他角色尤其 Assistant 代发。UI 继续拥有布局、动画、ActivityKit 和版本接纳；Actions 保留真实执行、资源和清理。Support 只提供可复用的发布、调用、队列和 Chat 执行机制。

只有 LLM 显式生成的 Action/Tool 的结果可触发 ReACT。自然语言的代码展开（字幕、TTS 播放）、等待态等均是内部调用；以每次调用来源标记区分，不能按函数路径推测来源。内部调用可以加入执行完成屏障，但结果与异常不得进入模型反馈上下文或触发再次推理。

## 实施范围

- Agents/Support：复用 AgentIslandPublication 的有界最新值发布与 joined stop，增加生产者绑定的内部调用接入；Chat round 记录 model/runtime 来源，解析器保留自然文本展开与显式模型 Action 的区别。模型调用结果和内部执行结果分开处理；拒绝未关联的 Tool 反馈作为新模型输入。
- Agents/Assistant：自有推理等待岛与任务岛分开；共享 Chat 只提供请求开始/首个输出/失败结束的等待事实回调，文案和展示调用留在 AssistantExecutionSession。
- Agents/SpeechPerception：在自有 capture、listening policy、识别 phase 生命周期中发布/结束灵动岛；不观察 UI 的 voicePhase。感知容器绑定自身 Gateway consumer。
- Agents/SpeechSynthesis：合成工作及播放开始/结束事实由本角色管理岛。播放器通过中立回调返回真实事实，角色绑定自己的 consumer；生产完成不能冒充扬声器 drain。取消/停机加入展示清理，异常保留原结果。
- Actions/Speech、ActionsBusinessBindings、Agents/Support 与 App/Composition：显式注入播放事实回调。频谱保留专用有界数据通道，由实际播放器更新，不逐帧发 Action 或 ActivityKit。
- Agents/Photographer、ApplicationControl：沿已有相机事实输入和连接事实输入管理各自岛，不增加集中 UI 状态观察器；摄像、窗口、音效的事务执行仍留在所属 Actions 能力。
- Actions/UI/Runtime、ActionsBusinessAssembly：移除 IslandDomainPresentation 集中业务观察和代发；保留通用 Island Action/权限/版本执行与频谱端口。
- Agents/Memory 的历史执行预览适配新增 runtimeAction 事件，仍展示实际调用，不参与反馈续轮。
- 测试：验证角色独立发布/结束、生命周期隔离、取消/失败、真实播放事实、同一路径不同调用来源以及内部异常不触发 ReACT；删除被替换集中投影器的测试。

不新增目录或模块。实现后同步所有涉及目录的 README、MobileHarness/README.md 及验证记录。原生 UI、真实模型和设备验收与自动化结果区分。

## 验证与完成

完成日期：2026-11-06。代码与设计文档已对齐，集中投影实现和旧测试已移除。针对性回归、./scripts/check.sh（包括普通与原生测试阶段）以及 ./scripts/build-ios.sh 四个构建目标全部通过；原定代码、清理、文档和必要自动检查范围完成。实际结果、首轮失败记录及真实模型/真机验收边界见 [专项验证](../validation/Agent-Presentation-Ownership.md)。
