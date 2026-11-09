# 相机照片查看、批量保存和直接关闭

- Camera.Capture.loadPreviewImage 继续接收单个 previewID，也接受 previewIDs JSON 数组一次替换选区。允许明确选取最多五张任意缓存照片。自动最新图只占用空位。新拍摄时，已满的显式选区释放最早的选项，为新照片腾出位置。批量准备共享相机的单操作槽，全部就绪且会话仍有效后才提交选区。Agents State、Chat、ModelKit 和历史预览共同支持五个附件，保留 16 MiB 总请求上限。
- Camera.Capture.saveAllPhotos 无参数。保留单张 savePhoto。批量在当前会话锁定快照下顺序保存全部未保存照片，报告各成功项和各失败项，保存成功的照片不会重存。已提交结果不因取消、失败或反馈音而撤销。关闭或结束会话加入在途工作。
- closeCamera 与窗口关闭直接清除未保存照片，保留已收录照片。closeCamera 不打开处置弹窗。若涉及未处置视频，返回明确失败，用户可用 saveVideo 或 ignoreVideo 后重新关闭。窗口按钮的视频处置交互继续由 CameraCoordinator 拥有。
- 同步 Photography、Camera、公共接口和模型附件说明。验证五张图通过完整模型请求、批量保存含部分失败及重试、关闭清理与 Action 配置。运行 scripts/check.sh 和 scripts/build-ios.sh。

同步历史相片栏和 Provider 请求的边界测试。压缩摄影教学的重复内容，使摄影及组合 Skill 继续符合现有提示词预算。

## 2026-11-09 验证

- 覆盖五张历史缓存照片进入 State 和模型请求、六张拒绝、批量选区校验、失败保留原选区、新拍摄恢复最新照片、批量保存部分失败与只补存待保存照片、关闭时取消分析并清空会话。
- scripts/check.sh 的首轮有一项机械臂跟踪断言失败。该用例单独复测通过，主集成套件复跑 1109 项通过。LiveRuntimeTests 229 项通过，原生相机 Metal 呈现用例通过。
- scripts/build-ios.sh 的四个 iOS 模拟器方案通过。摄影 Skill 配置和提示词与主 App 包一致。真机交互和真实模型五图比较待验收。
