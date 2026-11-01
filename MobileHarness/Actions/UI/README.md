# UI — 业务函数与执行设计

## 职责与模块关系

拥有表情、会话、视线／骨架、反馈、导航、资源及运行事实的呈现业务。RuntimePresentation 只实现呈现端口，弱绑定实际会话呈现者；相机、语音和 Task 执行由各自业务域端点实现。基础 UI 拥有页面、渲染器和可变显示状态。

Gateway 通过注册函数调用本域，Agents 决定请求与策略，App 注入唯一基础能力和根生命周期。本域消费 FunctionContracts 及需要的基础能力，不导入 Agents、Gateway 实现或 App。全部域内源码由 Actions 单一目标编译。

## 目录与文件

| 文件 | 当前职责 |
| --- | --- |
| [RuntimePresentation.swift](RuntimePresentation.swift) | 仅拥有 UI 呈现接入，弱绑定角色端点并保留身份／代际检查 |
| [ActionNamespaces.swift](../Support/Contracts/ActionNamespaces.swift) | Shared UIActions namespace only; callable implementations remain in the domain files below |
| [UIModule.swift](UIModule.swift) | 显式绑定通用呈现能力及可选诊断、蓝牙和加载状态端口 |

| 目录 | 责任 |
| --- | --- |
| [Conversation](Conversation/README.md) | 只接纳匹配会话、轮次、任务与序号的文字及显示状态，转换为基础 UI 自有值 |
| [Expression](Expression/README.md) | 有限表情完成包含自身覆盖恢复；持续基础表情和加载／请求等待状态以接纳完成 |
| [Feedback](Feedback/README.md) | 反馈与装饰值先校验范围，再由注入端点执行；PCM 生成是纯算法，不操作设备 |
| [Navigation](Navigation/README.md) | 导航只提交目标和真实调用上下文；导航端点决定呈现接纳，函数不持有页面或创建业务会话 |
| [Pose](Pose/README.md) | 视线和骨架是独立呈现操作，骨架载荷不拥有模型或页面 |
| [Resources](Resources/README.md) | 只呈现真实资源快照、结果与已分类错误，不发起下载或修改模型偏好 |
| [Runtime](Runtime/README.md) | 运行异常分类属于 ApplicationControl，本目录校验已分类值并呈现；蓝牙展示只更新事实，不连接或控制设备 |

[Support](Support/README.md) 仅维护跨业务能力共用的契约或算法。

## 接口与完成语义
| 模块 | 函数与参数 | 完成边界 |
| --- | --- | --- |
| Expression | express/setExpression：emotion；内部 setReplyWaiting：enabled/requestID | express 加入呈现与恢复；setExpression 接纳持续基础状态 |
| Caption | beginReplyTurn/finishTranscript 无参数；print/setTranscript：text | 端点接纳本轮或文字更新 |
| VoiceState | setVoiceState：listening/hearing/processing | 显示状态接纳，不产生麦克风效果 |
| Gaze | moveEyes：有限 x/y，均为 −1…1 | 视线目标接纳 |
| Pose | showPose：payload JSON | 全部骨架数据替换，空 people 清除 |
| HistoryPresentation | showHistory 无参数 | 注入的历史呈现端点完成 |
| Feedback | playCue：cue/volume；vibrate：style/intensity/count/intervalMS | 提示音实际排空；触觉为有界脉冲请求发出 |
| Notice | showNotice：text/tone/durationMS；dismissNotice 无参数 | 瞬时提示状态提交或自身提示清除 |
| Light | updateLight：enabled 及位置/透明度/强度/期限 | 装饰光状态提交，不等待渲染期限结束 |
| ResourcePresentation | showResources、showResourceFailure、showResourceOperationFailure、showResourcePreferenceFailure、showProviderResult | 端点呈现接纳，保留实际资源结果或 presented |
| Navigation | open：destination | 导航端点完成后返回 presented |

普通呈现函数静态预算为 5 秒，showResources 为 60 秒。setExpression 是 state kind，其余入口是 finite；finite 不表示所有视觉插值都要结束，应按各函数的 completion 理解。

## 关键参数与算法
express 支持 closed/smile/happy/laugh/thinking/surprised/sad/love/angry/scared/playful，拒绝 clear；setExpression 额外支持 clear。express 即使呈现或取消检查失败也尝试恢复自身覆盖；清理失败时 ExpressionCleanupFailure 保留 primary/cleanup 两个错误。

print 要求非空 text，最多 2000 UTF-8 字节；setTranscript 允许空文本作为清除，最多 4096 字节。beginReplyTurn 和 finishTranscript 拒绝参数。Gaze 校验有限数值范围。showPose 的实际参数读取及载荷上限见 [Pose](Pose/README.md)。

playCue 默认为 wake、volume=0.85；vibrate 默认为 heavy、intensity=1、count=1、intervalMS=80。七种 cue 和五种触觉风格是封闭枚举；volume/intensity 为有限 0…1，count 为 1…3，intervalMS 为 40…250。原生音频准入和触觉可用性属于宿主。

Notice 的非空文字限 1024 UTF-8 字节，tone 为 info/warning/error（默认 warning），默认期限 8000 毫秒。Light 的 x/y/initialOpacity/intensity 为有限 0…1，默认 0.5/0.4/0.85/1，默认期限 3000 毫秒。两类期限范围为 500…30000 毫秒；本域只提交请求，宿主拥有过期与清理任务。清除请求不表示清除真实错误记录或聆听策略。

资源呈现使用正 UInt64 generation；错误文本限 2048 字节，偏好错误 reason 为 invalidSource/recognitionRequired/synthesisRequired/execution。Provider 呈现使用 ID requestID，可选失败码最多 64 字节且以 provider. 开头，不传递 URL/密钥。导航目标为 home/settings/language/recognition/synthesis/vision/bluetooth/history。

[Actions 设计](../README.md) · [公共函数契约](../Support/Contracts/README.md)

WindowModule and WindowExecutionService in Navigation provide generic window controls. UI owns presentation; injected WindowContentLifecycle owns domain pause/resume/close. No device or Task state is copied into the window manager.
