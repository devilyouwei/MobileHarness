# UI/Feedback — 业务能力与执行

## 职责与关系

反馈与装饰值先校验范围，再由注入端点执行；PCM 生成是纯算法，不操作设备。提示音等待实际排空，触觉等待有界脉冲提交；瞬时提示和光效期限由基础 UI 根拥有。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [FeedbackActions.swift](FeedbackActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [FeedbackTone.swift](FeedbackTone.swift) | 固定七项提示音 PCM 的纯生成与音量缩放 |
| [LightActions.swift](LightActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [NoticeActions.swift](NoticeActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [UIEffectTypes.swift](UIEffectTypes.swift) | 瞬时提示与装饰光的值及端口 |
| [UIFeedbackTypes.swift](UIFeedbackTypes.swift) | 提示音、触觉请求和能力端口 |

## 反馈音频算法

FeedbackTone 的不可变静态 bank 缓存七种原始单声道 Float PCM，采样率 48000 Hz。samples 按已校验请求的 volume 缩放，不打开设备、不改变系统音量。wake/confirm/cancel/error/soft/save 使用多声部正弦、平滑起音、指数衰减和尾部包络；discard 使用固定种子的低通噪声、下降音与短点击。

| cue | 长度（秒） |
| --- | --- |
| wake | 0.94 |
| confirm | 0.38 |
| cancel | 0.40 |
| error | 0.46 |
| soft | 0.52 |
| save | 0.62 |
| discard | 0.58 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)
