# UI/Runtime — 业务能力与执行

## 职责与关系

本目录校验、执行已经由调用方决定的展示请求；运行异常分类属于 ApplicationControl，蓝牙显示函数只更新展示事实。Agent 使用自身绑定的 Gateway consumer 调用注册函数；Actions 不观察 UI 状态推断角色阶段，也不替角色调用灵动岛。

showHome 和 showSettings 以 Void 完成，调用方仍可收到结构化回执或实际失败。

| 文件 | 当前职责 |
| --- | --- |
| [BluetoothStatusActions.swift](BluetoothStatusActions.swift) | 已分类连接状态的参数校验和呈现 |
| [MicrophoneSpectrumPresentation.swift](MicrophoneSpectrumPresentation.swift) | 频谱测量校验、平滑及采集句柄／UI 代际接纳 |
| [IslandActions.swift](IslandActions.swift) | Action 声明、命令解析、模块绑定、可信身份、执行服务与图片端口 |
| [RuntimePresentationCapabilities.swift](RuntimePresentationCapabilities.swift) | 连接显示能力接口 |

[所属域设计](../README.md) · [Actions 模块](../../README.md) · [角色展示所有权](../../../Agents/README.md#role-owned-presentation-and-speech-facts)

## Island 执行与完成

IslandModule 注册 UI.Island.present/update/end/setPresentation。前三项为内部 Tool，setPresentation 提供 Action/Tool；内部发布不进入模型目录。IslandCommand 统一解析与字段校验，IslandActions.execute 经 IslandPresentationService 使用 UI 公共端口执行。生产者身份来自可信 invocation 的 source/session，内容不能指定 owner。发布、更新、结束使用 UI 的 owner/revision 校验；不能修改或结束其他生产者的内容。setPresentation 保留 Skill 授权的共享展开／收起权限，这不授予内容写权限。

setPresentation 接受 compact/expanded；expanded 必须有 detail。large/custom/animation/width/height 拒绝。回执的 submitted/localStatus/systemStatus 区分接纳、本地完成和系统提交；系统禁用或失败不抹除本地内容。UI 拥有布局、优先级仲裁、手动收起、动画、挂载及 ActivityKit 串行提交。根停止关闭服务；角色在生产者权限退休前加入自己的 end 和重试 worker 清理。

IslandContent 使用 primary/secondary 指标和 detail(text,thumbnail)，通用任务详情与顶部实时状态由 UI 独立选择。带详情的任务可自动展开；普通语音、相机、连接状态不提供详情。系统岛点击唤回当前 App 页面，不自动打开相机或设置。liveActivity=false 仅关闭该内容的系统投影。

IslandThumbnailPresenting 仅提供图片注册/释放，图片 owner 与活动提交者一致；Action 只传注册引用，不能读取任意文件或 URL。elapsed.startedAt 使用 Swift Codable Date（2001-01-01 UTC 起的秒数），拒绝无效和非有限日期；逐秒计时排版由 UI 负责。

## 生命周期、频谱与异常

各角色决定开始、内容和结束，复用 [AgentIslandPublication](../../../Agents/Support/README.md#agent-owned-island-publication) 的有界传输和错误处理；本目录没有领域观察 worker、蓝牙到期策略或角色阶段映射。实际播放频谱由 Speech/Listening 的播放器送到 UI 专用数据端口，麦克风频谱由 SpeechPerception 经 SpectrumPresenting 提交；两者不逐帧调用 Action 或 ActivityKit。

运行异常日志和写入接口见 [RuntimeLog](../../../UI/Components/RuntimeLog/README.md)。RuntimePresentation 校验业务会话、序号和代际；MicrophoneSpectrumPresentation 使用 UUID 句柄，旧句柄不能更新新采集。角色内部执行的成功、失败和异常由调用方处理，不向 Assistant 生成新的模型输入。
