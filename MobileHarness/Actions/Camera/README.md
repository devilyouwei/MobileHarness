# Camera — 业务函数与执行设计

## 职责与模块关系

拥有相机业务函数、原生采集／预览及照片处置。CameraModule 绑定七项 Capture 函数及一个私有 Album.perform 函数；CameraExecutionEndpoint 保留当前会话／业务状态准入，CameraCoordinator 管理采集，CameraPhotoSession 独立管理照片操作。

Gateway 通过注册函数调用本域，Agents 决定请求与策略，App 注入唯一基础能力和根生命周期。本域消费 FunctionContracts 及需要的基础能力，不导入 Agents、Gateway 实现或 App。全部域内源码由 Actions 单一目标编译。

## 目录与文件

| 文件 | 当前职责 |
| --- | --- |
| [ActionNamespaces.swift](../Support/Contracts/ActionNamespaces.swift) | Shared CameraActions namespace only; callable implementations remain in the domain files below |
| [CameraCapabilities.swift](../Support/Contracts/CameraCapabilities.swift) | 相机端口、镜头类型、照片回执及失败分类 |
| [CameraCoordinator.swift](CameraCoordinator.swift) | 采集、资源租约、预览、姿态与公开事实的根协调者 |
| [CameraExecutionEndpoint.swift](CameraExecutionEndpoint.swift) | 相机调用身份与会话准入，直接转发类型化回执 |
| [CameraInteractionWorkflow.swift](CameraInteractionWorkflow.swift) | 单槽操作提交、忙态与实际错误反馈 |
| [CameraModule.swift](CameraModule.swift) | 绑定相机与相册函数，不定义业务参数或调用协议 |
| [CameraPhotoSession.swift](CameraPhotoSession.swift) | 拍照／处置任务、媒体所有权、呈现确认和反馈作用域 |
| [CameraRuntimePorts.swift](CameraRuntimePorts.swift) | Injected resource arbitration interface and runtime dependencies; perception connections are supplied by App composition |
| [CameraStorageFactory.swift](CameraStorageFactory.swift) | 注入仓库并选择照片保留策略 |
| [CaptureActions.swift](CaptureActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [PhotoDispositionWorkflow.swift](PhotoDispositionWorkflow.swift) | 保存提交、动画、提示音与移除的实际完成组合 |

## 状态、完成与清理

CameraCoordinator 独占采集意图、租约续期、预览和姿态代际；CameraPhotoSession 独占一个拍照或处置任务、媒体所有权、缩略图确认和反馈作用域。两者通过只读前台／采集版本闭包连接；关闭取消并加入照片操作，再清理采集。保存已提交后，反馈失败不能抹掉 App 相册收录结果。照片存储策略最多 1024 张、2 GiB、仅淘汰未收录文件的 evictOldest，由 CameraStorageFactory 注入仓库和根路径。

## 接口与完成语义
拍摄地址位于 `Camera.Capture`，包含七个函数。相册内部入口另见下节。

| 函数 | 实际入口参数 | 返回与预算 |
| --- | --- | --- |
| open / close | 无 | 注入启闭完成后返回 operation/enabled；默认 30 秒 |
| flip | facing=front/back | 注入镜头切换完成后返回 operation/facing；默认 30 秒 |
| retry | 无 | 等待端点重试完成，Void/completed；默认 30 秒 |
| takePhoto | 无 | JSON：mediaID、width、height、mimeType；15 秒 |
| savePhoto | 可解析 mediaID ID | JSON：saved、mediaID、alreadySaved、可选 feedbackIssues；60 秒 |
| ignorePhoto | 可解析 mediaID ID | JSON：ignored、mediaID、alreadySaved、可选 feedbackIssues；默认 30 秒 |

每个入口拒绝未知键。ID 字符串最多 36 字节；缺省照片参数被传为 nil。open/close/flip 在调用前后检查取消；拍摄与处置在调用前检查取消，原生工作及其取消清理由端点实现。

## 数据流与失败边界
函数等待真实端点结果后编码回执，不推断模型就绪或物理效果。open/close 的 enabled 来自已完成的目标操作，flip 的 facing 来自已完成的目标选择；这些不是额外原生状态查询。照片像素和 JPEG 读取通过能力端口保留 source/session/input 所有权，不作为普通字符串参数传输。

生产端点检查前台、相机启用、操作重叠、照片身份与呈现状态。savePhoto 的 App 相册收录、离场呈现和反馈由端点组合；已收录的照片不会因后续反馈失败被撤销。回执可携带反馈问题。重复保存明确的已保存 ID 可返回 alreadySaved。ignorePhoto 处理当前预览，不表示删除相册照片。

本域没有请求队列、缓存或常驻捕获任务。权限拒绝、忙、未启用、后台或照片不可用通过类型化错误传播；是否已经发生部分效果以端点的实际状态和回执为准。

[Actions 设计](../README.md) · [公共函数契约](../Support/Contracts/README.md)

## 基础相册实施契约

savePhoto 改为 App 相册正式收录，不调用 Photos。新增 Album 服务与内部执行契约，分页40、原图并发2、缩略图并发4、变更单槽；保留收录照片不自动淘汰。


## 相册执行与请求附件

PhotoAlbumService 通过共享 CapturedPhotoStore 完成分页、读取、导入与删除，系统导出使用注入的平台能力。PhotoAlbumInvocation 携带 UI 自有类型化请求和私有结果槽，绑定 root session/request ID 并拒绝重复执行；角色与 Task 权限由 Agents 验证。Camera.Album.perform 仅注册为直接 Tool，不进入 Photography Skill；参数必须为空，媒体只经附件传递。

原图最多2个、缩略图最多4个活跃读取；变更单槽，重叠明确 busy。当前 Photographer 普通请求消费为串行，因此实际UI读取并发可能更低。批量导入最多20张，逐张检查／保存，保留成功项并返回各失败项；单次请求仍受120秒截止及根停止取消加入约束。Photos提交后等待原生事务，取消不撤销已完成副本；不自动重试或跨重启重放。

缩略图在工作任务内通过Image I/O有界下采样，不存入原片区。原片、照片ready、App收录和系统副本是独立事实。

删除回执区分逻辑删除成功与文件清理问题；逻辑提交后即从当前UI列表移除，清理失败明确提示并保留恢复状态。

## Container 上下文

CameraCoordinator.contextSnapshot 读取 CameraCapturing.isRunning 的真实结果，再提取当前呈现／照片流程事实；没有独立公开Writer或运行状态缓存。CameraPhotoSession 不再为模型镜像发送更新通知。原有实时UI事实流继续服务实际UI请求。

## Execution ownership and lifecycle

ActionsContainer retains the camera and native cleanup. CameraExecutionEndpoint checks business/session state, not role names. CameraInteractionWorkflow is an Actions-owned UI request facade with one worker; shutdown closes admission, cancels and joins it. CaptureActivityEvent remains a camera-owned event. App supplies resource/perception collaboration through neutral ports. Album attachments use the generic per-request slot; Agents authorizes the caller before Gateway admission.
