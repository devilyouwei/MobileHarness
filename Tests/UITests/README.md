# UI State and Interaction Tests

## 职责与边界

根 Package.swift 的 UITests target 只依赖 UI，测试 UI-owned 状态和值，不引用 App、Agent、数据库、模型或设备实现。以 Swift 状态测试为主；常驻导航使用原生 macOS 挂载回归，iOS 触摸/渲染验收另行进行。

✅ PersistentHomeNavigationTests 在 macOS 原生 SwiftUI/AppKit 窗口中挂载与生产相同的常驻导航容器，验证多层 push/pop、覆盖时首页原生视图身份/窗口挂载、持续状态更新与 page task 不取消，以及根销毁时清理。该回归不替代 iPhone 的 Core Animation、语音和物理动作验收。

## 当前用例

| 文件 | 契约 |
| --- | --- |
| SettingsStateTests | 草稿与已确认值、独立语音模式、操作准入、错误/显式重试与保留未提交编辑 |
| BluetoothConnectionStateTests | 连接/打开详情/不可用意图、已连接与记忆分组、失效回调、断连操作约束 |
| AudioDetectionStateTests | PCM freshness 与方向独立过期、quiet/unavailable、可执行角度清理 |
| ConversationHistoryPresentationTests | 请求行/任务索引、分页游标与重试、原始 JSON/图像引用、时间/缺失值、初次加载 gate 和返回详情保留页状态；native-only/mixed Tool Call 展示、实际结果/失败保留与未测计时不补造 |
| ExecutionLogTests | 完整子错误、Channel/task 分组、终态/取消与展示值 |
| EyeGeometryTests / ListeningMotionTests | 几何、眼睛/聆听运动、epoch 和有限状态 |
| PhotoDepartureTests | 照片退出状态、身份 fence 与完成条件 |

测试操作使用注入结果及明确完成信号；执行结果到 UI 值的映射属于 AppWorkflowTests。历史页的返回保留检查验证 gate/缓存状态，不声称已验证 native List 的真实滚动位置。

CaptionPresentationTests 覆盖部分文本→最终修订、定稿与移动不丢字符、连续替换、320 Character 上限、emoji/组合字符的 UTF-16 范围及 Reduce Motion。不以值测试代替原生 UILabel/动画帧率验收。

## 待实现

- 原生 List 分页/下拉刷新/返回手势和滚动位置保持。
- 真实图片/长历史/错误展示、布局、动画与辅助功能验收。

运行结果与设备证据记录到 [validation](../../docs/validation/README.md)。

✅ 历史 token 展示覆盖缓存读取/写入、零值、缺失与旧 JSON 兼容；不从总输入反推缓存命中或费用。


## 分类异常诊断

✅ 验证诊断详情的有界保留及短 userMessage 展示，不将错误详情直接塞入 toast。

## Platform 根、设备接入与同帧呈现

✅ CameraFramePresentationTests 验证图像独立提交、姿态失败不清图、姿态独立过期、重复/错帧拒绝和渲染故障的代际围栏。测试使用合成像素，不代表 Metal 上屏或真实摄像头验收；证据见 [专项验证](../../docs/validation/PlatformKit-Containers.md)。

✅ CameraFramePresentationTests 另覆盖相机渲染最新槽的合并、排空后的再接纳、停止拒绝，以及骨架网格的缓存、容量、镜像和方向约束；不以状态/几何测试替代原生显示链与 GPU 线程的设备验收。

✅ macOS 上直接运行生产 CameraMetalRenderer，合成 Metal 兼容像素并验证真实 display-link/GPU 完成、无帧停止及反复启停/同图层接管。测试不使用真实相机或 YOLO，不代表 iPhone 上屏性能验收。

✅ 相机到期回归按可观察状态作有界等待，替代固定 90 ms 睡眠，允许原生窗口与主线程调度在不同机器上有合理抖动；仍断言姿态过期时新鲜影像保留。

## UI 容器与相机能力注入

✅ 新增 UI 根/相机容器隔离、生命周期围栏、清屏、到期任务加入与停止后拒绝媒体回归，并保留相机独立输出和原生 Metal 回归。

## UI 全量容器化

✅ 应用级 UI 状态由八个子容器统一创建，消费者注入所需 Presenting 接口并提交 UI 自有值，不直接写字段。App 注册并管理同一 UI 根；原业务身份/版本校验、原生完成和基础库依赖边界保持。跨模块连接迁移仍是独立待办。

✅ EyeGeometryTests 覆盖频谱原生路径的固定拓扑、32 段上限、非有限输入清理、失活和 Reduce Motion 的数值隔离；真实图层插值与帧率仍须真机验证。


✅ UI 回归直接覆盖根、字幕、表情、几何、历史分页及 Metal；渲染测试以实际 GPU 完成计数判断，不以状态接纳代替真实完成。

✅ 已补充连续帧延后到期、更早捕获期限、清屏后重新接纳及重复停止／释放回归；光环重复停止、无帧退出与所有者释放测试仅在 iOS 编译／执行，不将 macOS 状态测试视为该原生测试通过。带在途 GPU 帧的光环退出及真机功耗仍待验收。
