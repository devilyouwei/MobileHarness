## 摄影：照片与录像
### 事实与准入
拍照、摄影和录像使用相机窗口。打开视觉、跟踪和跟随属于 application-control 和 Vision.open，摄影不启用后台视觉。
actions.camera 提供意图、忙闲、权限和预览。platform.vision.camera 提供实际启动状态、阶段和朝向。未知表示未就绪。只有用户要求且 lensOwner=capture 时才切换镜头。
BasicSkill 决定 Task 的开始和结束。读取 AGENT CONTEXT 中的 task。独立保存、关闭或切换镜头不必新建 Task。只结束已实际创建的匹配任务。报告忙碌或权限阻碍；retryCamera 需要明确意图。
### 拍照
openCamera 打开或恢复就绪预览，不拍照。takePhoto 需要可见相机且会选择拍照模式，不能代替打开或恢复相机。将已知的打开、切换或设置、口语和拍摄步骤放在一个响应；依赖结果的决策才等反馈。
新拍摄在打开与拍照之间用简短口语提示。用各自 wait 排序相机和语音 Channel。已打开时省略 openCamera，已说过提示时省略重复提示。
takePhoto delaySeconds=0...30 只覆盖这次的延迟。0 表示立即，省略沿用设置。倒计时无需 configureCamera 或模型计时。只拍一次，等实际 previewID 后再报告、查看、保存、关闭或重拍。
savePhoto 需要当前准确 previewID。全部保存使用一次 saveAllPhotos，包括未选中照片。按回执报告各项成功和失败。alreadySaved 和 feedbackIssues 不表示应重复已提交操作。部分失败保留失败预览与任务，等用户决定。
明确重拍留在同一任务和窗口。旧照片在窗口关闭或缓存淘汰前可重新加载。保存不会拍照，取消不撤销保存。关闭清理不保留的照片。
### 录像
startRecording 打开或恢复窗口，选录像、关闭闪光灯，保留镜头、缩放和拍照延迟。不先发 openCamera 或 configureCamera。durationSeconds=1...600 覆盖时限，省略保留现值，初始是 600。
先在 wait 里说提示，再发 startRecording，之后不输出内容。省略 waitForCompletion 即 true，录像停止且文件就绪后才返回。false 只用于 UI 启动确认。录像暂停聆听，使用停止按钮或时限；最小化继续，进入后台则收尾且不会再次启动。录像中禁止更换镜头或拍摄设置。stopRecording 需要实际 recordingID。
ready 表示结束并就绪。报告真实 duration 和 fileName，询问保存或忽略。仅凭 ready 不可声称已保存或仍在录制。saveVideo 和 ignoreVideo 要用实际 recordingID 和明确用户意图。mediaID 是待处理媒体；savedMediaID 不能证明视频内容。使用 App 相册，不把视频作为图片发送。失败后不自动重拍；用户明确要求重试才可对仍保留的片段再次保存。
### 设置与窗口
configureCamera 仅修改提供的字段。mode 为 photo 或 video，delaySeconds 为 0...30，flash 为 off、on、auto，zoom 为 1...6 且受设备限制，durationSeconds 为 1...600。录像用 flash=off，待处理媒体会阻塞切换模式。cancelCapture 停止并等待本地倒计时。configureCamera 和 unloadPreviewImage 为 void 成功。以后需要已生效设置或预览列表时查 State。
匹配 Task 已确认保存或忽略后用 task.end，保留窗口。明确关闭时，先等 operation=close 且 enabled=false 再确认。只关闭 Capture，不关闭 Vision。已关闭时不重发。待处理录像须先明确保存或忽略，处置、关闭和结束分回合。关闭失败或取消保留 Task 和窗口；不要重放已完成操作。无匹配 Task 时直接确认。
Window.* 使用 ui.windows 的实际 windowID，move 的 x/y 范围为 0...1。openCamera 成功不触发下一轮，已知捕获步骤需同回合发出。最小化保留拍摄窗口和录像，镜头控制交还后台视觉。处置前恢复窗口。窗口按钮会让用户选择如何处理待处置录像。后台停止采集，重新打开需明确意图。
Island.setPresentation 使用实际 activityID，size 为 compact 或 expanded。只有详情文本或缩略图能展开。新详情自动展开，更新保留手动收起。任务详情和瞬时状态独立。不要重复计时、周期刷新或强制展开，UI 管理动画，iOS 决定系统展开。submitted 表示已提交，localStatus 和 systemStatus 分别描述实际状态。

### 拍照示例，每段都是独立响应
仅预览：
```xml
<openCamera/>
```
打开并切换到用户要求的后置：
```xml
<openCamera/><flipCamera facing="back"/>
```
打开、提示、拍照，同一响应：
```xml
<wait><openCamera/></wait><wait>看镜头，现在开拍。</wait><takePhoto/>
```
已经打开，给提示：
```xml
<wait>看镜头，现在开拍。</wait><takePhoto/>
```
已打开并已提示：
```xml
<takePhoto/>
```
打开，三秒倒计时，已经说过提示：
```xml
<openCamera/><takePhoto delaySeconds="3"/>
```
打开、提示、三秒倒计时，同一响应：
```xml
<wait><openCamera/></wait><wait>看镜头，三秒后拍照。</wait><takePhoto delaySeconds="3"/>
```
已打开且用户明确要求立即拍摄：
```xml
<takePhoto delaySeconds="0"/>
```
获准保存，使用实际 previewID：
```xml
<savePhoto previewID="preview_1"/>
```
要求全部保存时：
```xml
<saveAllPhotos/>
```
查看实际缓存 ID：
```xml
<loadPreviewImage previewIDs='["preview_1","preview_2","preview_3","preview_4","preview_5"]'/>
```
按请求重拍，保留旧照片：
```xml
<takePhoto/>
```
确认保存且任务匹配，保留相机：
```xml
照片已保存到 App 相册。<task.end summary="照片已保存到 App 相册"/>
```
要求丢弃：
```xml
<closeCamera/>
```
关闭成功并清空会话：
```xml
相机已关闭。<task.end summary="相机已关闭，未保存照片已清空"/>
```
无 Task 的保存确认：
```xml
照片已保存到 App 相册。
```
### 录像示例，每段都是独立响应
启动录像，先给提示：
```xml
<wait>开始录像，结束时请点停止按钮。</wait><startRecording/>
```
请求十秒，无需 configureCamera：
```xml
<wait>开始录制十秒视频。</wait><startRecording durationSeconds="10"/>
```
已经准备：
```xml
<startRecording/>
```
收到就绪回执后，使用真实时长：
```xml
录像已结束，时长十秒。要保存到 App 相册，还是忽略？
```
获准保存，使用实际 recordingID：
```xml
<saveVideo recordingID="11111111-2222-4333-8444-555555555555"/>
```
用户授权忽略：
```xml
<ignoreVideo recordingID="11111111-2222-4333-8444-555555555555"/>
```
确认保存且任务匹配，保留相机：
```xml
视频已保存到 App 相册。<task.end summary="视频已保存到 App 相册"/>
```
忽略后结束匹配 Task，保留窗口：
```xml
视频已忽略。<task.end summary="视频已忽略"/>
```

### 跨轮预览图像
从 actions.camera.preview 读取真实当前 ID。图像附件是可见证据，State 将 ID 映射到附件位置。loadPreviewImage(previewID) 追加一项选择。使用 JSON 数组 previewIDs 可替换为 1–5 张照片。最新照片填空位，满时移出首项。只比较用户要求且已附上的照片。卸载移除选择。

每个窗口按先入先出保留最多 20 张原件。重拍保留旧照片，已保存原件也可重新加载。隐藏窗口暂停图像投递，关闭使 preview_N 失效。相册 media_N 独立。缺少图像证据时不得自行重拍。
