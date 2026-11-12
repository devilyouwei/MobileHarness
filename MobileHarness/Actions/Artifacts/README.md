# Artifacts — 当前作品与编辑

本目录拥有确定性文件编辑、格式验证、运行渲染和导出，不执行模型请求。ArtifactWorkspace使用StorageDatabase.WorkspaceStore协调当前目录与SQLite文件索引；StorageFiles拥有沙盒和原子文件操作。源码仅保存在writer/workspace_N/relative-path，不保存持久历史版本。支持HTML/CSS/JS/SVG/JSON/TXT/MD，不新增源码或任务累计配额。

ArtifactsModule 从 WorkspaceActions 的声明表注册独立的 Artifacts.Workspace 函数。Writer 通过 Gateway direct 调用作品库检索、打开、删除、文件读写和渲染。start/resume/describe/preview/publish 由 Writer 运行时授权并调用。函数地址选择实际操作，各操作有独立的参数声明。Assistant 只能委派，不暴露作品库 Action，服务拒绝其直接调用。Writer 的可信 delegateID 绑定编辑会话，workspaceID 定位持久工作区，模型参数不能更改所有者。ArtifactService 拥有单项会话准入及项目单写锁；ArtifactEditing 拥有单流、按文件版本失效的读取引用和范围修改。remove 要求有效读取引用且禁止入口删除。完整文件内容通过中立 ArtifactStreaming 端口背压追加，不通过 Tool 参数。发布要求最新草稿已进行显式渲染，存在已报告的运行错误时拒绝发布；窗口不可见时显式返回不能进行视觉验证，不能把保存等同视觉验收。

## 执行与续写生命周期

Gateway 的 edit 工具完成表示已创建编辑流，不表示文件已写完或委托已完成。工具入口同时校验原始 sessionID 与 delegateID，续写校验 delegateID/streamID；恢复经 start/resume 创建新会话和新的流身份。Writer 拥有模型与委托生命周期，Actions 拥有实际效果和编辑资源，内容分片无需重复提交 Gateway。

edit 接纳返回 ArtifactEditPreparation。编辑器从同一事务取实际路径、原始指令、项目文件列表或选区与相邻文本，并校验关联文件的版本和范围。Writer 使用这些事实组装内容请求，Actions 管理编辑校验、数据与业务结果。

ArtifactService 跟踪全部工具、追加、完成、中止和截图操作：全局最多八项、零等待队列；每委托最多一个变更操作和一个预览/截图操作，竞争显式 busy。追加由调用者逐次等待形成背压。预览独立于变更通道，返回时只更新仍匹配编辑代次的预览字段，不用旧会话副本覆盖新的写入或完成状态。取消请求会传播到实际任务并等待其退出；非协作依赖仍需真实返回，不能宣称已停。

revoke 立即关闭该委托普通准入并取消在途普通操作，已开始的 abort 只等待、不再次取消。release 合并并发调用，先围栏并加入在途工作，再保存中断草稿、关闭 editor 和释放项目锁。abort 的检查点失败仍尝试关闭流，原始错误和清理错误保留。release 清理失败后服务关闭准入，后续 release/shutdown 继续返回失败。Actions 根调用 shutdown 关闭全部准入、取消/加入普通工作并清理剩余会话，先于依赖的窗口服务关闭。已发生的文件效果不回滚；被取消的工具不得把已落盘内容描述为从未发生。

ArtifactPresentation 连接 UI 页面/窗口与 StorageFiles 临时预览；每作品双缓冲目录，与网页共用最多十二个窗口。关闭清理预览和页面、不取消 Writer，流不会重开窗口；新委托 start 或显式 open 才解除关闭标记。删除清理窗口绑定及预览。TXT 转义显示。Markdown 由 UI 的离线转换器解析，Mermaid 围栏转换成静态 SVG 图像。无效图保留围栏源码，转换诊断并入显式 render 的回执。Writer内部preview命令按ArtifactContentParser安全检查点读取当前流或草稿，由Writer自有worker决定呈现；它不证明 HTML/JavaScript 语法有效。未完成草稿禁用脚本，完整渲染由 WebKit 执行并返回诊断/截图。项目索引可列出仅有草稿的中断作品，用户可显式委托恢复。

同项目呈现通过独立串行门合并为安全磁盘/导航顺序，最多两个可取消等待者，超限显式 busy；不同项目仍可独立进行。关闭先标记页面退出，导航中断返回“草稿保留、视觉验证不可用”，再加入呈现并清理双缓冲目录；最小化期间保留最新快照供恢复时呈现。Writer 的 open/delete 同样持有项目锁，不能与正在编辑的项目并发。

## 文件工具与修改一致性

所有操作限定在 StorageFiles.workspaces 内，不使用 Shell。目录由相对文件路径隐式形成，不保存空目录；list(path) 返回目录下文件和字节数。move/removeTree 在读取全部受影响文件后验证整个候选草稿再更新，拒绝穿越/覆盖/路径冲突；入口禁止删除，移动入口同步更新 entry，链接内容不自动改写。相对文件的新建和最后文件的删除分别形成/移除隐式目录。

read 返回内容、起始行、字符范围、文件版本和宿主引用。limit 指定正数行数或字符数，省略时分别读取 60 行或 2500 字符，后续读取可使用 nextOffset。修改文件只失效该文件引用，其他引用继续有效。edit 的 contextReferences 使用同一会话的有效读取引用，宿主校验版本后装配关联片段。字符 start/end 可进一步缩小已读取范围。edit 指令、搜索词、作品标题和相对路径没有 Artifacts 自定长度门槛。相对路径仍校验文件类型、路径成分与沙盒，实际文件系统错误由存储层报告。


## 预览与诊断

编辑流约200ms保存可恢复草稿，append/complete不执行或等待页面重载。内部preview可以读取进行中的安全检查点，跳过相同/空入口快照，并禁用脚本；呈现节流、合并、加入由Writer拥有。显式render执行完整文件组合。修改使上次渲染资格失效；finish前置条件不足抛renderRequired，不与发布CAS冲突混淆。

呈现返回结构化 status（preview/observed/errors/unavailable）、页面文本和诊断；服务补充草稿代次，终态保留验证状态。observed 只说明已取得页面观察，不证明视觉或任务语义正确；未知呈现器状态为 unverified。窗口隐藏/关闭返回 unavailable，不伪造成功截图。finish 拒绝已报告运行错误；Writer 决定修复、继续或明确报告验证限制。

## 作品浏览、导出与历史操作

ArtifactExportService 是根拥有的作品读取/导出业务，UI 通过 WriterArtifactsControlling 接口访问。读取一次完整、带草稿/已发布标识的快照，导出期间不追随 Writer 的后续修改。源文件保持 UTF-8，预览/历史读取/导出不另设更小的源码大小门槛；全部文件通过 ArtifactArchive 生成标准无压缩 UTF-8 ZIP，保留相对目录、CRC32 和中央目录，无 Shell/第三方压缩依赖。

HTML/MD/TXT 可导出 PDF；作品窗口、历史文件预览和 PDF 复用 ArtifactTextRendering 的 Markdown/TXT 文档输出，HTML 保持关联资源。Markdown 转换不修改现有工作区源码。源文件在 workspaces/exports 的唯一暂存目录中生成，独立 WebPageContainer 通过受控根渲染，导出不占用/重载作品窗口。单次导出 worker、零等待队列；分享完成清理，取消加入 worker 并清理，根关闭取消/加入，首次导出回收上次进程残留。分享文件保留到系统分享关闭；容量、渲染和清理错误显式反馈。PDF 静态导出，不承诺保存动画状态。

ArtifactService 只拥有作品业务，不提供历史 startNew/delete/title 命令。Writer 长期任务与对话读取由 Agents/Writer 和 Storage 的委托记录接口管理。

Writer 显式 create 或 enter 时调用工作区 start。初始化工作区时，缺失入口随草稿检查点创建为空文件，已有入口保留内容。窗口显示准备占位或已有内容，回执报告真实入口是否存在及为空。写入空入口可由宿主取得零长度读取引用，有内容的文件仍需要模型提供有效读取引用。展示失败撤销内存会话与写锁，保留已落盘草稿。

内部 start 为新委托恢复窗口，resume 为同任务续作保留关闭/最小化偏好；两者均非 Writer 模型可选择的编辑命令。Assistant 显式打开作品也恢复最小化窗口。

任务文件预览使用独立暂存快照与 UI 受控 WebPageContainer，本地资源根、网络阻断和导航策略保持一致。预览和导出各仅一个 worker、零等待队列；根关闭取消并加入，预览离页请求取消并清理。首次临时目录清理由共用的准备任务合并，不能在首次导出时删除正在展示的预览。SVG 使用 HTML 宿主渲染；CSS/JS/JSON 转义显示并可作为文本 PDF 导出。分享关闭才清理对应导出文件。

新项目在显式 create 的首次 checkpoint 中建立 writer/workspace_N 目录；续作直接修改当前文件。SQL写租约排除并发写者，单文件原子替换后提交索引；失败保留真实文件和草稿状态，后续读取校验索引，不从模型日志恢复代码。

start 的 createWorkspace 参数由受信 Writer 运行时为未完成初始化的预留项目传入，不暴露给模型工具 schema；模型循环不允许 start/resume。已有就绪项目缺失保持 missingProject。预览与 PDF 的临时 HTML 使用与发布一致的 UTF-8 BOM，源文件导出保持原始 UTF-8 文本。

工具失败区分 invalidReadRange、invalidInstruction、invalidTitle 与 invalidQuery，并报告对应参数要求。达到共享窗口上限时明确报告容量不足。

ZIP 导出依据标准 ZIP 的字段宽度预检条目数、源码字节和偏移；需要 ZIP64 时明确 archiveFormatLimit，建议导出单文件，不产生整数转换崩溃或截断档案。此边界只约束该导出格式，不约束模型生成/文件编写。

局部编辑 context 明确选区是否以换行开始/结束；内容作者应在非空替换中保留这些分隔符，避免相邻行被合并。宿主不猜测源码、不自动插入换行，原子替换仍只覆盖读取引用选区。

replace使用fresh read引用约束字面旧文本，唯一匹配后原子替换为新文本，保留选区外及选区内未匹配部分；无匹配/多匹配明确ambiguousMatch，过期/跨文件引用readRequired。空新文本删除匹配，禁止空旧文本。成功修改失效该文件引用、保存草稿并清除render状态；引用/匹配校验失败不改变草稿，不修改当前文件；后续Storage检查点失败明确传播，不伪装保存成功。操作完全使用StorageFiles和内存字符串，不执行shell。

连续呈现以每项目 previews/<workspaceID> 作为稳定 WebKit 读取根，两个快照槽各保存一个唯一版本子目录，另保留一个稳定 preview.html 宿主文件直到项目关闭；相对资源使用新版本 URL，避免复用过期 CSS/图片缓存。只回收非当前槽，不因版本变化更换原生页面。preview 调用 UI 的同文档增量能力，完整 render 调用保留视口的本地导航；新页面/安全域仍由 UI 隔离。取消及项目锁继续覆盖写入、呈现和清理，关闭作品不重开窗口。

## 标题、副标题与后台快照

会话标题在start接纳，首个edit的可选title随后续文件检查点保存；rename独立持久化标题，续作沿用。describe为Writer运行时更新操作subtitle，不改源码或模型上下文。ArtifactPresentation将这些通用显示值提交WindowState；重名仅在活动窗口显示层加稳定创建顺序后缀，业务标题不带序号。

每项目最多一份latest快照，最多十二项目；Scene隐藏不创建窗口/写预览资源/调用WebKit，返回deferred并保留最新文件。显式render可留下deferred验证证据供finish保存，不能宣称视觉检查通过。Actions 持有一个场景预览恢复任务。前台接纳后异步启动，按项目锁重新读取最新快照，避免排队旧副本覆盖新文件或名称；关闭/删除已退休的快照不复活，最小化不恢复。场景隐藏或 Actions 停止取消并加入恢复任务。恢复失败记入对应窗口与日志，保留快照并继续处理其他窗口。后续成功渲染清除本次窗口诊断。Writer 发起的 preview/describe 命令经 Gateway direct。

窗口身份在等待首次呈现前预留并绑定，切后台导致回执中断时保留同一窗口，不按标题猜测归属。正在渲染时隐藏转换为 deferred，截图不可见返回 nil。显式文件与渲染命令保留原始失败结果。UI窗口生命周期与Writer执行独立。后台CPU/进程存活由系统控制，本能力不伪造后台运行权限。

## Workspace and editing identities



Writer passes a workspace_N identity to library, editing and preview interfaces. ArtifactService dispatches by canonical Action path. Each open uses the selected workspace gate and reports its own window result. Library inventory includes workspaceID, title, entry and state. Storage derives the writer/workspace_N directory from the typed identity.

## Current workspace persistence

ArtifactWorkspace validates formats and delegates current-directory storage to StorageDatabase.WorkspaceStore.
The neutral repository indexes files in shared SQLite; source bytes live only in StorageFiles at
writer/workspace_N/relative-path. Checkpoints replace current files, and finish marks the current content
accepted after rendering. No historical version catalogue or restore-version tool exists. The UUID
current token fences stale publication; it is not a retained version. Temporary editor savepoints are
in-memory undo state for one active session. Web/render/export snapshots remain separately owned,
short-lived copies and never create workspace history. Missing files fail explicitly. Deletion requires an inactive workspace without a write lease.

workspace.search、workspace.open 和 workspace.delete 只接受 Writer 委托调用。workspace.search 通过 SQLite 返回当前页命中元数据。open 和 delete 接受精确 workspaceID，校验 writer 所有者并取得单项目锁。删除所需的搜索命中由 Writer 工作流校验。open 呈现已有入口并返回窗口证据，保留文件与草稿状态。删除先清理展示，再删除存储。显式进入或打开聚焦已有窗口，最小化期间预览仅更新最新快照。窗口转换被打断时保留快照，明确关闭才退休。
