# Audio — 原生音频、反馈与数值能力

## 职责与公开协议

AudioContainer 按有限命名作用域缓存原生实现，对外返回 AudioInputOutput、CuePlaying、HapticFeedbackProviding。AppleAudioIO／NativeCuePlayback／NativeHapticFeedback 实现这些端口；业务只注入需要的协议，SDK 不依赖其他项目模块。

协议覆盖权限、原生PCM／事件订阅、播放／频谱、运行事实及停止／加入；便利重载只转发明确参数，不替代驱动、不伪造成功。样式、PCM、错误和设备事实均为 SDK 自有值，Signal 转换在 Gateway。

## 源码与所有者

| 文件／类型 | 职责 |
| --- | --- |
| AudioContainer | 有限作用域、实例缓存、原生会话互斥和根停止 |
| AppleAudioIO / AudioInputOutput | 捕获／播放接纳，原生完成及清理 |
| SpatialAudioCapture / AudioSampleBufferReader | 空间采集、格式／连续性及原生buffer读取 |
| MicrophoneFrame / AudioCaptureContext | 原生PCM、布局、输入／支持／回退事实 |
| AudioCaptureReadiness | 首个有效帧的可取消就绪门 |
| AudioSpectrum / StreamingMonoPCMResampler | 有界频谱计算、持续单声道转换 |
| NativeCuePlayback / CuePlaying | 单次原生PCM反馈播放 |
| NativeHapticFeedback / HapticFeedbackProviding | 有界触觉、预备生成器和取消 |
| ListeningCaptureWorkflow | 单worker、最新原生启停意图的取消加入 |

## 录音与输入

✅ startCapture 在支持的内置路由优先尝试FOA，否则选择mono。空间启动失败必须停止并加入后再尝试mono；仅允许接纳前回退。已接纳流不改变布局，格式／中断／连续性失败明确终止。

两后端都在首个有效入队PCM后返回就绪，静音也有效，不伪造首帧超时回退。mono请求1024样本，回调验证1…8192帧；FOA为四声道ACN/SN3D，时间连续误差不超过两样本，每传输包最多4000帧／16000标量。

主录音直接返回原生64包有序源流，不经过MainActor逐包中转。最多16个可选观察订阅，各自64包，慢订阅局部overflow并明确结束。NativeInputSession 关闭围栏后迟到回调不能污染新流。stopCapture 关闭接纳并加入空间后端／原生回调。

AudioCaptureContext 区分输入、空间支持和接纳前回退；原生读buffer受声道／格式边界约束，保留OSStatus及CMBlockBuffer至同步提取完成。

## 播放与完成

✅ NativePlaybackGraph 私有actor拥有输出引擎、播放器、格式、mixer tap及原生连接／启动／PCM提交／停止，避免这些同步原生调用阻塞MainActor。AppleAudioIO只持有主线程接纳、token和完成等待。

最多三个已调度PCM buffer、一个串行提交；单包非空、最多262144样本、有限数值、8…192kHz、mono。消费端保持同一次流的采样率，真实dataPlayedBack回调释放容量并确认排空。onStarted仅在首块提交且player启动成功后回调，不代表声音已到达用户。

stopPlayback同步失效token并唤醒等待，单个清理任务加入原生停止；waitForPlaybackStop、根stop及下一次播放加入清理。旧取消不能停止新播放，未完成原生调用返回前不伪造停机。

playClip拒绝捕获／播放冲突，复用同一播放端口；主因和清理错误分别保留，释放不触碰替代会话。引擎内部可复用健康连接，不提供无人使用的独立预热／播放游标API。

## 频谱、转换与反馈

AudioSpectrum 每次最多2048样本，measureOffMain 在通用执行器运行、前后可取消；同步计算保留供明确调用。播放频谱只在MainActor取tap快照和token，计算后复核同一播放；取消／替换返回nil，无播放返回静音。

StreamingMonoPCMResampler 持有连续AVAudioConverter，输入为有限mono、8…192kHz；格式变化重建转换器，reset清状态。多声道提取和VAD／ASR策略属于调用者，不在转换失败后伪造PCM。

CuePlaying使用一个AVAudioPlayer／delegate，重叠明确busy，取消停止并加入自己的播放器，不主动重配共享AVAudioSession。PCMClipEncoding只编码有界、最多1秒／192000样本的PCM16 WAV。

HapticFeedbackProviding使用公开支持检查、缓存生成器和一个有主人的operation；最多三次触觉、间隔40…250ms，取消和停止加入，UIKit只确认请求发出。触觉预备不承诺实际产生反馈。

## 原生事件、错误与约束

NativeAudioEvent 是事实而非Error。路由按前后输入／输出portType+UID比较，categoryChange/override及同设备重配不打断流；实际设备变化、不可用路由和缺少旧快照保守投递routeChanged，不直接上报容器故障。

中断仅在began且实例有活动采集／播放时报告AudioIOError.interrupted；ended不重复终止。格式、连续性、overflow、执行和清理失败保留原throw及注入报告。事件两个worker由原生所有者取消并加入，不由页面持有。

❌ 原生路由、实际声音／触觉、持续模型负载及硬件连续性仍需真机验收。

[PlatformKit](../README.md) · [Core](../Core/README.md)
