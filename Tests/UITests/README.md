# UI State and Interaction Tests

## 职责与边界

根 Package.swift 的 UITests target 只依赖 UI，测试 UI-owned 状态和值，不引用 App、Agent、数据库、模型或设备实现。这里是 Swift 状态单元测试，原生触摸/渲染验收另行进行。

## 当前用例

| 文件 | 契约 |
| --- | --- |
| SettingsStateTests | 草稿与已确认值、独立语音模式、操作准入、错误/显式重试与保留未提交编辑 |
| BluetoothConnectionStateTests | 连接/打开详情/不可用意图、已连接与记忆分组、失效回调、断连操作约束 |
| AudioDetectionStateTests | PCM freshness 与方向独立过期、quiet/unavailable、可执行角度清理 |
| ConversationHistoryPresentationTests | 请求行/任务索引、分页游标与重试、原始 JSON/图像引用、时间/缺失值、初次加载 gate 和返回详情保留页状态 |
| ExecutionLogTests | 完整子错误、Channel/task 分组、终态/取消与展示值 |
| EyeGeometryTests / ListeningMotionTests | 几何、眼睛/聆听运动、epoch 和有限状态 |
| PhotoDepartureTests | 照片退出状态、身份 fence 与完成条件 |

测试操作使用注入结果及明确完成信号；执行结果到 UI 值的映射属于 AppWorkflowTests。历史页的返回保留检查验证 gate/缓存状态，不声称已验证 native List 的真实滚动位置。

CaptionPresentationTests 覆盖部分文本→最终修订、定稿与移动不丢字符、连续替换、320 Character 上限、emoji/组合字符的 UTF-16 范围及 Reduce Motion。不以值测试代替原生 UILabel/动画帧率验收。

## 待实现

- 原生 List 分页/下拉刷新/返回手势和滚动位置保持。
- 真实图片/长历史/错误展示、布局、动画与辅助功能验收。

运行结果与设备证据记录到 [validation](../../docs/validation/README.md)。
