# Camera — 业务函数与执行设计

## 职责与模块关系

Camera owns capture, cached previews and disposition. CameraModule binds eleven Capture functions, four Video functions, four Perception functions and private Album.perform. CameraExecutionEndpoint validates invocation scope; CameraCoordinator owns native capture and CameraPreviewStore owns temporary image state.

Gateway 通过注册函数调用本域，Agents 决定请求与策略，App 注入唯一基础能力和根生命周期。本域消费 FunctionContracts 及需要的基础能力，不导入 Agents、Gateway 实现或 App。全部域内源码由 Actions 单一目标编译。

## 目录与文件

| 文件 | 当前职责 |
| --- | --- |
| [ActionNamespaces.swift](../Support/Contracts/ActionNamespaces.swift) | Shared CameraActions namespace only; callable implementations remain in the domain files below |
| [CameraCapabilities.swift](../Support/Contracts/CameraCapabilities.swift) | 相机端口、镜头类型、照片回执及失败分类 |
| [PerceptionActions.swift](PerceptionActions.swift) | 背景视觉／跟随的 openVision、closeVision、retryVision、flipVision，模型别名 Vision.* |
| [CameraCoordinator.swift](CameraCoordinator.swift) | 采集、资源租约、预览、姿态与公开事实的根协调者 |
| [CameraExecutionEndpoint.swift](CameraExecutionEndpoint.swift) | 相机调用身份与会话准入，直接转发类型化回执 |
| [CameraInteractionWorkflow.swift](CameraInteractionWorkflow.swift) | 单槽操作提交、忙态与实际错误反馈 |
| [CameraModule.swift](CameraModule.swift) | 绑定相机与相册函数，不定义业务参数或调用协议 |
| [CameraRecordingSession.swift](CameraRecordingSession.swift) | 录像启动/终态/素材处置；与显式设置共享原生配置及回滚事务 |
| [CameraPhotoSession.swift](CameraPhotoSession.swift) | 拍照／处置任务、预览身份、呈现确认和反馈作用域 |
| [CameraPreviewStore.swift](CameraPreviewStore.swift) | 原图缓存目录、最新图与显式选择、分析图准备和保存／忽略 |
| [CameraRuntimePorts.swift](CameraRuntimePorts.swift) | Injected resource arbitration interface and runtime dependencies; perception connections are supplied by App composition |
| [CameraStorageFactory.swift](CameraStorageFactory.swift) | 注入仓库并选择照片保留策略 |
| [CameraCaptureWorkflow.swift](CameraCaptureWorkflow.swift) | Canonical open 子Action与最终拍摄的失败即停组合；只返回最终媒体回执 |
| [CaptureActions.swift](CaptureActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [PhotoDispositionWorkflow.swift](PhotoDispositionWorkflow.swift) | 已提交保存／忽略结果与提示音失败分离 |

## 状态、完成与清理

CameraCoordinator owns native demand/leases; CameraPhotoSession joins capture and display feedback. CameraPreviewStore owns temporary bytes/selections/disposition. Persistent album storage remains1024 files/2GiB and cannot evict collected media. Background joins native work without deleting cached previews.

## 接口与完成语义
拍摄地址位于 `Camera.Capture`，包含十一个函数。相册内部入口另见下节。

| 函数 | 实际入口参数 | 返回与预算 |
| --- | --- | --- |
| open / close | 无 | 组合窗口/设备启闭完成后返回 operation/enabled；open 增加 windowID；60 秒 |
| flip | facing=front/back | 注入镜头切换完成后返回 operation/facing；默认 30 秒 |
| retry | 无 | 等待端点重试完成，Void/completed；默认 30 秒 |
| takePhoto | none | JSON: previewID, width, height, mimeType; 110 seconds including open/countdown/capture |
| savePhoto | previewID | JSON: saved, previewID, mediaID, alreadySaved, optional feedbackIssues; 60 seconds |
| ignorePhoto | previewID | JSON: ignored, previewID, optional feedbackIssues; 30 seconds |
| loadPreviewImage / unloadPreviewImage | previewID | 更新调用方的显式图片选择并返回最新 metadata；30 秒 |

All entries reject unknown parameters. Photo disposition requires an exact previewID, at most64 bytes. Native work owns cancellation/cleanup; committed saves are not undone by presentation failure.

## 数据流与失败边界
函数等待真实端点结果后编码回执，不推断模型就绪或物理效果。open/close 的 enabled 来自已完成的目标操作，flip 的 facing 来自已完成的目标选择；这些不是额外原生状态查询。预览像素通过类型化 State 附件传输；选择绑定可信调用 session，不接受模型提供 scope。Web 截图的持久媒体读取仍验证 source/session/input，不作为普通字符串参数传输。

Disposition works by cached preview identity, including non-displayed images. Save returns a durable mediaID and optional feedback issues; repeated committed saves return alreadySaved. Ignore cannot delete persistent album media.

takePhoto/startRecording 在同一父调用内复用 canonical open 子Action：窗口关闭时打开、最小化时恢复、已打开时聚焦并复用原生采集；确认后才进入拍摄。前置失败后将拍摄标记notStarted，不自动重试或丢弃媒体；成功子报告不能覆盖最终照片／录像JSON。open仍可单独使用以只预览。子步骤不重新进入Gateway，不产生中间ReAct。takePhoto在需要时切photo并保留已有zoom/flash/delay/duration，配置失败加入回滚。

Action 函数本身没有请求队列或缓存；CameraCoordinator 拥有唯一采集/租约工作者。权限拒绝、忙、未启用、后台或照片不可用通过类型化错误传播；是否已经发生部分效果以端点的实际状态和回执为准。

[Actions 设计](../README.md) · [公共函数契约](../Support/Contracts/README.md)

## 基础相册实施契约

savePhoto 改为 App 相册正式收录，不调用 Photos。新增 Album 服务与内部执行契约，分页40、原图并发2、缩略图并发4、变更单槽；保留收录照片不自动淘汰。


## 相册执行与请求附件

PhotoAlbumService 通过共享 MediaStore 完成分页、读取、导入与删除，系统导出使用注入的平台能力。PhotoAlbumInvocation 携带 UI 自有类型化请求和私有结果槽，绑定 root session/request ID 并拒绝重复执行；角色与 Task 权限由 Agents 验证。Camera.Album.perform 仅注册为直接 Tool，不进入 Photography Skill；参数必须为空，媒体只经附件传递。

原图最多2个、缩略图最多4个活跃读取；变更单槽，重叠明确 busy。当前 Photographer 普通请求消费为串行，因此实际UI读取并发可能更低。批量导入最多20张，逐张检查／保存，保留成功项并返回各失败项；单次请求仍受120秒截止及根停止取消加入约束。Photos提交后等待原生事务，取消不撤销已完成副本；不自动重试或跨重启重放。

缩略图在工作任务内通过Image I/O有界下采样，不存入原片区。预览缓存、App收录和系统副本是独立事实。

删除回执区分逻辑删除成功与文件清理问题；逻辑提交后即从当前UI列表移除，清理失败明确提示并保留恢复状态。

## Container 上下文

CameraCoordinator.stateSnapshot 只报告拍摄／视觉业务意图、镜头操作持有者、工作／权限条件及照片事实。原生 running、phase、facing 和照片尺寸由 PlatformKit 的 platform.vision.camera 发布。读取均无设备操作。

## Execution ownership and lifecycle

ActionsContainer retains the camera and native cleanup. CameraExecutionEndpoint checks business/session state, not role names. CameraInteractionWorkflow is an Actions-owned UI request facade with one worker; shutdown closes admission, cancels and joins it. CaptureActivityEvent remains a camera-owned event. App supplies resource/perception collaboration through neutral ports. Album attachments use the generic per-request slot; Agents authorizes the caller before Gateway admission.

## Passive inspection

ActionsBusinessAssembly only includes an already-created camera owner; the absent owner is an explicit uncreated node. Inspection does not evaluate lazy camera/cue construction. Business holds enabled/perceptionEnabled/lensOwner, photo activity, permission requirements, displayed/saved identity and local failure. Vision connection, foreground and worker existence are Runtime. No native running/facing mirror is published by Actions.

Preview frame adaptation forwards the native optional portrait sensor reference into CameraVideoFrame without changing gravity-upright capture dimensions, pose coordinates or JPEG orientation. UI owns scene orientation and final preview/skeleton/gaze projection; Actions does not query interface geometry or reorient inference input.

CameraResourceAccess.isSettled asks whether resource handoff has reached a stable holding; a new stable lease can satisfy it. It does not imply that the resource is unowned. Gateway owns the holding interpretation through the App protocol adapter.

## Camera window lifecycle

CameraCoordinator implements WindowContentLifecycle using the root WindowState injected by ActionsBusinessAssembly. Camera.Capture.open presents/restores the unique Camera window then awaits native capture and an admitted fresh preview frame through CameraPresenting.waitForPhotoCaptureRotation; the receipt adds optional windowID. Failure keeps the window and existing camera failure/retry interface. Photo opening never enables the independent Face visual/following branch. Camera.Perception.openVision enables only that branch.

Minimize rejects conflicting photo work and hides rendering, retaining the photo branch and its capture demand. Restore mounts before confirming readiness. The shared capture composition restores a minimized window and awaits native readiness before photo/video work. Closing performs save/discard/cancel in the window; cancel retains identity. Photo and visual demand are independent: a healthy existing capture/lease is reused when adding or removing either branch. Only zero demand releases the lease and joins native stop. Background clears both demands and joins pose/preview/photo cleanup; foreground does not restart solely because a window exists.

The preview worker feeds one immutable display frame shared by both surfaces. A separate pose task exists only for visual demand. Enabling/disabling pose joins only that task, without cancelling preview or restarting hardware. Native lens changes invalidate old pose/gaze and join the perception/tracking scope before renewing frames; old mechanical targets cannot survive that scope. Model failure preserves preview. Photo and video modes share this graph; video installs a movie output without removing the preview source.

Lens control is admitted by the same UI presentation projection used by buttons: the visible expanded Camera window takes priority; minimized/closed/fully covered camera windows yield to enabled visible Face vision. Other windows never acquire control. No visible camera surface means no holder. Capture.flip and Perception.flipVision have fixed sources; caller parameters cannot choose a more privileged source. Native switching stays in CameraCapturing. Requested facing is distinct from displayed actual facing and is published only after successful native completion.

Window lifecycle begin/end gates lens requests across real presentation completion. Beginning a transition joins an admitted native worker; closing cancels and joins photo work, while minimize/open/settings keep their explicit busy checks. At most one demand mutation and one native worker are admitted; excess requests fail rather than queue. Cancellation/background invalidates capture revision and UI generation. Presentation does not acknowledge photo success.

CameraInteractionWorkflow maps typed UI intent through Photographer and Gateway into fixed Capture, Video or Perception functions. No UI callback directly starts/stops/switches native capture.

System permission prompts can invalidate the active scene's request generation. The interaction facade reports cancelled/stale/unavailable requests as explicit retry guidance, preserves committed photo saves, and never exposes UI request enum codes as user-facing errors. It does not automatically replay the interrupted operation.

## Capture settings and recording

Capture.configure replaces mode/photo-video, delaySeconds0…30, flash/off-on-auto, zoom1…6 (further bounded by hardware), durationSeconds1…600. Validation is pure; native capability checks remain in CameraCapturing. Failed mode/settings changes join rollback before reporting failure. Settings and supportedFlash/maximumZoom are exposed by actions.camera. Capture.cancelCapture cancels and joins only the owned countdown. CameraCountdown uses monotonic absolute deadlines inside photoTask; cancellation/background prevents the subsequent shutter and clears the display.

VideoActions.swift owns Camera.Video.startRecording/stopRecording/saveVideo/ignoreVideo; CameraModule binds all explicitly. startRecording defaults waitForCompletion=true: it waits for native didStart and the recording's single joined completion, returning state=ready/mediaID/fileName/actual duration/stopReason only after file preparation and audio handback. Its budget is780 seconds (60 for opening plus720 for at most600 seconds recording and startup/finalization). Explicit false has a120-second budget (60 for opening plus60 for startup) and returns only recordingID/state=recording at didStart, with no later result from that invocation. Photographer's fixed interactive Tool supplies false so the UI/role request slot remains available for stop. Business code does not branch on call protocol. A model's scheduled start remains pending while the UI stop Tool executes independently of ChannelScheduler. Cancellation of the terminal waiter stops only the matching recording, joins its completion and cancellation worker, then propagates cancellation; actual finalization failure is preserved. Stop joins didFinish, validates the file and publishes an uncollected video before state=ready; neither receipt means album collection. Native duration/size completion follows the same path. Stop/save/ignore use a real UUID recordingID. Invalid identity, permission, busy, file validation and cleanup failures propagate.

The coordinator recording primitive consumes the ready Camera surface supplied by the Action composition and accepts either photo or video mode. Optional durationSeconds1…600 overrides the current limit; omission preserves it. Within the owned startup task it prepares video mode and flash=off, preserving lens, zoom and photo delay. Already matching video settings skip configuration. CameraCaptureConfiguration in CameraRecordingSession.swift is shared with configureCapture and photo-mode preparation: native mode/settings changes finish before presentation commits; failure/cancellation joins rollback and retains both original and cleanup failures. Pending photo/video blocks startup. Coordinator holds its mutation gate through preparation and didStart; microphone handoff follows successful configuration. Window opening belongs to the preceding canonical open step; the recording primitive never disposes of media.

CameraRecordingSession owns one start task, one joined completion and at most one pending clip; no page owns them. It joins listening pause and full native audio-owner release before native start, and waits for native audio release and pending-file validation/publication before attempting to resume the original valid listening generation. Failed startup releases the hold. Minimize preserves recording and presents a generic activity label; recording blocks both surfaces' lens controls. Close stops and asks save/ignore/cancel. Background synchronously invalidates the recording’s listening-resume permit, joins stop/finalization, retains the clip for later decisions and never automatically reopens capture/listening, even after a quick foreground return. Window transitions reject startup/finalization/disposition conflicts.

Raw native movie files remain owned until explicit save/ignore. The store publishes a bounded file copy and keeps a pending mediaID. Save removes the source before album commit, then clears preview; repeated confirmed save returns the cached receipt. Ignore removes the uncollected copy and source; collected media cannot be discarded through this endpoint. Failed preparation retains the source and identity for explicit retry or ignore. Active capture/recording and an undisposed video clip block overlapping capture; retained photo-cache entries do not. Duration limit is600 seconds and movie size512MiB; App album total remains2GiB/1024 files.

PhotoAlbumService routes video thumbnails through NativeAlbumMovie and returns validated local URLs for playback/export; it never loads a whole movie into Data. Native export uses VisionContainer's root-owned joined import slot. Image/model reads retain image-only budgets. The same album supports collection, playback, export and deletion; duration is derived from the native asset rather than a new SQL schema.

Photo capture freezes presentation.snapshot.photoCaptureRotation after countdown/readiness checks, immediately before the native shutter. Recording freezes the same window-derived angle after audio handoff and before beginRecording. Missing live geometry rejects unavailable; gravity-only rotation and Face orientation do not override the photo window. Native JPEG metadata and movie transforms remain authoritative for thumbnail, playback and storage; Actions does not rotate or crop encoded media after capture.

Photographer沿其既有相机事实输入管理倒计时、照片处理、录像和待处置灵动岛，以自身身份调用Gateway内部展示工具。Camera仍拥有原生事务和窗口/音效执行；系统岛不控制设备或释放相机，点击唤回App当前页面。取消倒计时、停止录像和保存继续经UICameraContainer→Photographer→Gateway→Camera Action，停止请求绑定recordingID。

Opening and native session running are not interchangeable with capture geometry readiness. The automatic open step awaits fresh preview geometry before completing. PhotoSession rechecks after the countdown; RecordingSession rechecks after mode configuration and microphone handoff. Both revalidate foreground/cancellation after the wait before calling Foundation. Missing initial frames wait for admission rather than immediately returning unavailable; a bounded timeout or root invalidation fails the current Action and never fabricates a capture result. The UI owns frame waiting only; Actions retains device/lifecycle authority.

CameraCoordinator创建相机Window时提供UI.WindowIcon.emoji("📷")；图标属于显示元数据，图标资源校验和卡片尺寸由UI Window组件拥有，不参与设备权限或采集生命周期。

## Session previews, State and gallery

CameraPreviewStore owns the open-window image session and model selections over StorageCache.cameraImages. Local preview_N IDs start at1 in each session and stay unchanged when the oldest of20 images is evicted. Storage owns original/analysis bytes and Camera-written disposition facts; Camera owns prepare/load/unload/save/ignore policy. One preparation/disposition is admitted; endSession invalidates pending work, joins it, then clears memory. PhotoSession separately cancels/joins capture and presentation. Root close seals the business owner; a new camera window opens a fresh scope.

New captures automatically load the latest image. Each context can additionally select three cached images, including ignored/saved images. Model-image preparation is bounded to1568px/1MP/1MiB; failure retains the original and explicit analysisFailure. New capture replaces the default slot; explicit selections survive until unload, disposition, FIFO expiry or session close. Dialog reset drops explicit selections only. Minimized, occluded and background windows retain memory but withhold model facts/images; restoring visible Camera restores selected images. Background Vision does not own or extend this image session.

Save passes bytes without preview/session identity to MediaStore under generic album ownership (source=album, empty session/input), publishes an independent media_N, marks saved and unloads all matching State selections without deleting the cached original. Repeat save returns the same media_N; ignore marks ignored, unloads, and can later be followed by save/load. Ignore rejects saved images and never deletes album records. Feedback failures preserve committed results. Gallery browsing changes no model State and starts no inference.

Model snapshots carry private resource bindings outside facts/manifest. Camera operations require the request's actions.camera.preview scope to match the current cache; UI requests capture that scope before queuing. History reads actual submitted bytes only from full request logs, independently of Camera, with no preview-to-album mapping or cache fallback. Scope IDs are not model-facing identifiers.

The gallery receives typed metadata and scoped read access through CameraInteractionWorkflow. Its stack counts all cached images irrespective of status. Capture presentation is one acknowledged arrival transaction; save/ignore update catalog flags and cue feedback without removing gallery entries. Closing prompts once if unreviewed images remain, then clears the session after joined work. Video disposition remains independent.

CameraPreviewStore owns a cancellable image-preparation task. Closing cancels it and joins completion before clearing bytes; non-cooperative callbacks remain generation-fenced. Window transitions reject new preview operations. pendingCount includes only unsaved, non-ignored entries for the single close confirmation.

历史 Prompts 图片由日志独占；本目录不提供相册或预览缓存的历史图片回退接口。实时相机和独立相册的读取不受日志清理影响。
