# Speech Support — 播放、聆听能力与目录绑定

## 简介

定义两个异步能力端口、聆听反馈值和 SpeechModule 的函数目录。接口保留真实 invocation，以便宿主核对音频/会话所有权并记录实际子结果。

## 上下游关系（一级）

```mermaid
flowchart LR
    Entries[Speech 函数入口] -->|能力与反馈类型| S[Speech/Support]
    Host[App 播放及捕获端点] -.->|协议实现| S
    Catalog[Actions 共用目录组合] -->|构造目录| S
    S -->|两项函数定义| Catalog
    UIValues[Actions/UI] -->|CueRequest 与 HapticRequest| S
    Contracts[FunctionContracts] -.->|目录和输入类型| S
```

## 内部模块关系

```mermaid
flowchart LR
    Module[SpeechModule] --> Playback[SpeechPlaybackCapability]
    Module --> Listening[SpeechListeningCapability]
    Listening --> Feedback[SpeechActions.ListeningFeedback]
    Feedback --> Cue[UIActions.CueRequest]
    Feedback --> Haptic[UIActions.HapticRequest]
    Module --> Error[SpeechActionError]
```

## 接口与绑定

SpeechPlaybackCapability 的 `play(audioID:invocation:)` 接受 UUID 与标准输入，端点负责音频取出、原生排空和清理。SpeechListeningCapability 的 `updateListening` 接受 enabled、paused、revision、ListeningFeedback 和 invocation；策略的接纳条件、取消与启动流程由实现者负责。

ListeningFeedback 在 `ListeningFeedback.swift` 中组合已校验的 UI 提示音与触觉请求，不含设备句柄。`SpeechModule.swift` 保存 capability 并绑定 speak/update；前者必需，后者可选。`SpeechTypes.swift` 当前只有 Foundation 导入，没有独立值类型。

✅ 两项定义通过 Void handler 返回 completed。如果子工作已向 invocation.results 记录报告，报告由执行层保存；目录本身不把报告重编码成字符串。

## 生命周期与失败

缺少聆听端点明确抛 listeningUnavailable；播放参数错误为 missingAudio。端点异常继续向执行层传播。模块不拥有合成器、PCM 缓存、策略状态、订阅或请求队列；闭包引用端点的寿命随目录持有者管理。

[Speech 入口设计](../README.md) · [UI 反馈接口](../../UI/Support/README.md) · [共享契约](../../Support/Contracts/README.md)
