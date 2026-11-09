# 删除 Channel 覆盖与照片忽略

日期：2026-11-09。

## 需求与实施方案

- 删除模型输出中的 channel.NAME 作用域，不保留兼容解析。Action 只使用注册 Channel；保留正常 Channel 调度和 wait 屏障。
- Agents/Support/Core/Generation 删除 ChannelParser、FunctionToken 的覆盖字段与边界事件、AgentGenerator 的文本 Channel 状态；wait 的数量和深度限制由 FunctionTokenParser 直接维护。Capability 的解析、内部调用和权限校验固定到各自声明的 Channel；Chat 文本映射不再接受覆盖参数。
- 删除 Camera.Capture.ignorePhoto 的声明、注册、能力接口、执行端点、Photographer 输入、UI 按钮和类型化请求；删除缓存 ignored 状态及保存/忽略分支，收敛为单一保存操作。保存的幂等性、反馈失败和取消语义保持。
- 重拍直接调用 takePhoto，旧照片按当前会话的20张FIFO保留，可通过 loadPreviewImage 再次读取；关闭相机窗口清空会话。视频忽略是独立能力，不在本次删除范围。
- Resources 的 Photography 配置、提示教学、示例及模型评估场景同步删除旧功能和旧别名，不保留兼容路径。
- 残留审计发现 discard 提示音只有照片忽略使用：删除 UI/Feedback 的该音效生成、共享 Cue 枚举值及 UI/Speech 声明的参数选项；保留独立视频忽略业务。同步这些目录的现行设计和音效回归。
- 更新整体设计以及 Generation、Capability、Chat、Camera、Photographer、UI/Camera、Storage/Cache/Image 和相关上级 README；同步现行需求。历史 ADR、测量数据、验证记录和原始 Technical_Design.docx 保留为历史证据，不当作当前契约。

## 验收

- 回归覆盖注册 Channel 不可覆盖、wait 嵌套/限制、旧作用域明确失败、重拍后旧图可加载、保存幂等及窗口关闭过期。
- 全仓检查代码、配置、教学、构建引用及兼容分支残留；旧语法仅允许出现在拒绝回归和历史证据中。
- 执行 ./scripts/check.sh 和完整 Xcode 下的 ./scripts/build-ios.sh，分别记录自动检查、构建及未执行的真实模型/原生 UI/物理设备验收。

## 执行记录

代码、配置、教学、UI 及专用音效删除完成。最终 `./scripts/check.sh` 和四项 iOS Simulator 构建均通过。签名构建 `2026110902` 已原位安装到 iPhone 17 Pro。真实模型和原生相机交互仍待验收。首次失败、复核和安装结果见 [验证证据](../validation/Remove-Channel-Override-And-Photo-Ignore.md)。
