# 0015 · 分句 FunctionToken 与共享 Actions

> Historical scope: Historical implementation layout and queue values. [ADR 0020](0020-layout-alignment.md) moved the source layout; later synthesis uses [ADR 0055](0055-synthesis-agent-audio-handles.md). Current contracts live in module READMEs.

状态：已采纳，2026-09-24。

## 背景

Assistant 通过 ChatCapability 生成回复。用户要求把文本也视为第一类行为信号：逐句发出 say 和 print，以局部标签动态绑定真实函数；同模块顺序执行，不同模块并行。GhostShell 完整方案尚未提供，本次只实现自然文本分句。

此决策按用户明确要求调整 Tech_Design.md §8.1 / §16 的函数实现归属。原方案与原始 Word 保持不改，当前目录约定由此 ADR 补充。

## 目录与编译边界

采用 `MobileHarness/Actions`：Action 表达对用户、界面或设备执行的行为，可复用于不同 Agent；不是推理能力，也不是需要结果继续决策的 Tool。

```text
Actions/
  Runtime/
    ActionRegistry.swift       显式注册逻辑路径与 handler
    ActionExecutor.swift      模块 FIFO、并行、取消与完成屏障
  Speech/
    Say.swift                 TTS 合成并等待实际播放结束
  Display/
    Print.swift               向显示 sink 追加文本
    Smile.swift               向显示 sink 发出表情
```

同属 Display 的 smile 复用显示模块。后续仅在有真实行为实现时增加模块，不预建空的机器人、移动或表情控制层。根 Package.swift 映射同一份源码为独立 Actions target；AgentCore 保留中立契约，Agent 不 import Actions，ModelKit 不依赖任何业务层。

## 注册与解析

`ActionPath(module:function:)` 属于 AgentCore。`AgentDescriptor.functionBindings` 声明局部标签到路径的映射，例如：

| 局部标签 | 真实逻辑路径 | 行为 |
| --- | --- | --- |
| say | Speech.say | 合成文本并播放 |
| print | Display.print | 追加屏幕文字 |
| smile | Display.smile | 显示表情 |

Agent 输出 `FunctionToken(name: "say", parameters: ...)`，不输出可执行代码或任意路径。ResponseGateway 验证可信来源和 Descriptor，查局部绑定，使用 ActionRegistry 找到 handler 后入队。不同 Agent 可以把相同局部标签绑定到不同路径。

Swift 不提供任意字符串到 Swift 函数的通用安全反射。因此“按路径执行”具体采用显式编译的路径白名单与闭包注册，不使用 Objective-C selector、动态加载或字符串求值。App composition root 注册函数实现并注入所需窄服务；未知标签、缺失路径、非法参数和不可用能力明确失败。

## 流式文本规则

Assistant 继续依赖 ChatCapability，逐个消费模型增量。暂存文本直到常见中日韩、拉丁及其他语言短句断句符号；每个完成的短句分别发出 say 和 print，普通结束时冲刷无末尾标点的尾句。分句器保留连续标点、闭合引号和空白，等待后续字符确认边界，识别小数及有限英文缩写。不同模型增量的切分不应改变句子顺序或重复文本；不承诺完整自然语言句法分析。

当前自然文本里出现的 XML 字符不会被解释成其他行为，也没有标签转义或嵌套解析承诺。未来 GhostShell parser 可以产出相同的 FunctionToken，由现有注册和执行层处理。FunctionToken 和 ToolCall 保持不同协议。

生成输入最多 4 KiB、输出最多 256 tokens / 2000 UTF-8 字节 / 60 个短句、生成上限 30 秒。短句未到标点时仍受整个回复预算约束，不形成无界缓冲。取消或异常不冲刷未完成残片；正常完成才把整轮回复写入最多 4 轮、1600 Character 的会话历史。

## 调度与完成语义

ActionExecutor 以 `ActionPath.module` 为串行边界。同模块 FIFO 包括 handler 的所有异步等待；Speech.say 只有在真实播放结束后才完成，不能把音频加入播放器队列就视作完成。Display.print 与 Speech.say 属于不同模块，可以并行，因此字幕可能领先朗读。不同 Agent 绑定同一模块也共用该执行器的串行约束。

每模块队列默认最多 32 项（含正在执行项），同时跟踪的运行输入默认最多 64 个。接纳不足时明确报错，不能丢句、覆盖或自动重试设备动作。网关接纳动作后返回，模块 worker 承担耗时执行；慢 TTS 不堵塞其他模块。

`assistant.finished` 表示模型本轮正常生成结束，不代表声音已播放结束。ResponseGateway 等待同一输入所有已接纳动作完成，之后 App 延迟 350 ms 恢复聆听。不能在每个 say 完成时提前接收新语句。输入 ID/session/generation 继续提供结果关联和旧会话隔离。

## 取消与错误

用户关闭录音时，App 经 RequestGateway 发送同 session 的 assistant.cancel，取消生成与输入队列；同时取消旧轮动作、停止播放，并等待模型 unload 和语音会话清理后才允许重启。取消不冲刷半句。已显示或已播放的内容不可能撤回；未来设备动作也不能把取消宣称为回滚。

推理、接纳或动作执行失败都必须报告原因，停止本轮语音；不以部分成功伪装成完整回复。完整机器人参数授权、物理急停、持久幂等与跨进程调度仍在后续范围内。

## 验证范围

需要覆盖增量跨标点边界、无标点尾句、多语言与 Unicode、取消残片、局部标签映射、未知路径拒绝、同模块完整异步串行、跨模块并行、队列满和完成屏障。本轮 scripts/check.sh 通过，其中 IntegrationTests 共 35 项通过；scripts/build-ios.sh 的五个 scheme 与签名真机 App 构建均通过。不以协议替身或构建成功代替真机体验验收。

真机仍需验收首句延迟、逐句语音衔接、连续对话、停止时残留音频和模型语义质量。当前为完整短句的连续合成播放，不是句子内部尚未完成文本的增量 TTS；不支持播放中抢话。App iOS 27、资源打包白名单及模拟器仅供界面调试的约束不变。

同一输入广播给多个 Agent 时，执行追踪键为 `(source AgentID, inputID)`；完成、失败和单输入取消仅作用于来源 Agent。session 取消可跨 Agent 清理本次会话，模块串行队列仍由所有 Agent 共享。
