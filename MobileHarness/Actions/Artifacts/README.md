# Artifacts — 当前作品与编辑

本目录拥有确定性文件编辑、格式验证、运行渲染和导出，不执行模型请求。ArtifactWorkspace使用StorageDatabase.WorkspaceStore协调当前目录与SQLite文件索引；StorageFiles拥有沙盒和原子文件操作。源码仅保存在agent/task_N/relative-path，不保存持久历史版本。支持HTML/CSS/JS/SVG/JSON/TXT/MD，不新增源码或任务累计配额。

ArtifactsModule 暴露 Artifacts.Workspace.perform；Assistant 通过 Writing 的 XML Action 调度作品管理，Writer 通过 Gateway direct 原生 Tool 编辑作品。Assistant 仅能列出、打开、删除作品；Writer 的可信 delegateID 绑定编辑会话，agent/taskID 定位持久工作区，模型参数不能更改所有者。ArtifactService 拥有单项会话准入及项目单写锁；ArtifactEditing 拥有单流、128 个按文件版本失效的读取引用和范围修改。remove 要求有效读取引用且禁止入口删除。完整文件内容通过中立 ArtifactStreaming 端口背压追加，不通过 Tool 参数。发布要求最新草稿已进行显式渲染，存在已报告的运行错误时拒绝发布；窗口不可见时显式返回不能进行视觉验证，不能把保存等同视觉验收。

ArtifactPresentation 连接 UI 页面/窗口与 StorageFiles 临时预览；每作品双缓冲目录，最多四个页面。关闭清理预览和页面、不取消 Writer，流不会重开窗口；新委托 start 或显式 open 才解除关闭标记。删除清理窗口绑定及预览。TXT 转义显示；Markdown 支持标题、引用、列表、围栏代码、强调和 HTTP(S) 链接，其余语法保留可读文本。Writer内部preview命令按ArtifactContentParser安全检查点读取当前流或草稿，由Writer自有worker决定呈现；它不证明 HTML/JavaScript 语法有效。未完成草稿禁用脚本，完整渲染由 WebKit 执行并返回诊断/截图。项目索引可列出仅有草稿的中断作品，用户可显式委托恢复。

同项目呈现通过独立串行门合并为安全磁盘/导航顺序，最多两个可取消等待者，超限显式 busy；不同项目仍可独立进行。关闭先标记页面退出，导航中断返回“草稿保留、视觉验证不可用”，再加入呈现并清理双缓冲目录；最小化期间保留最新快照供恢复时呈现。Assistant 打开/删除同样持有项目锁。

## 文件工具与修改一致性

所有操作限定在 StorageFiles.workspaces 内，不使用 Shell。目录由相对文件路径隐式形成，不保存空目录；list(path) 返回目录下文件和字节数。move/removeTree 在读取全部受影响文件后验证整个候选草稿再更新，拒绝穿越/覆盖/路径冲突；入口禁止删除，移动入口同步更新 entry，链接内容不自动改写。相对文件的新建和最后文件的删除分别形成/移除隐式目录。

read 返回内容、起始行、字符范围、文件版本和宿主引用；line/limit 选择 1...100 行，返回内容最多 2500 字符，通过 nextOffset 继续。修改文件只失效该文件引用，其他引用继续有效。edit 的 contextReferences 最多八项、合计 24KB；宿主校验版本后装配关联片段，不接受模型伪造来源。字符 start/end 可进一步缩小已读取范围。参数数值解析失败明确拒绝。


## 预览与诊断

编辑流约200ms保存可恢复草稿，append/complete不执行或等待页面重载。内部preview可以读取进行中的安全检查点，跳过相同/空入口快照，并禁用脚本；呈现节流、合并、加入由Writer拥有。显式render执行完整文件组合。修改使上次渲染资格失效；finish前置条件不足抛renderRequired，不与发布CAS冲突混淆。

呈现返回结构化 status（preview/observed/errors/unavailable）、页面文本和诊断；服务补充草稿代次，终态保留验证状态。observed 只说明已取得页面观察，不证明视觉或任务语义正确；未知呈现器状态为 unverified。窗口隐藏/关闭返回 unavailable，不伪造成功截图。finish 拒绝已报告运行错误；Writer 决定修复、继续或明确报告验证限制。

## 作品浏览、导出与历史操作

ArtifactExportService 是根拥有的作品读取/导出业务，UI 通过 WriterArtifactsControlling 接口访问。读取一次完整、带草稿/已发布标识的快照，导出期间不追随 Writer 的后续修改。源文件保持 UTF-8，预览/历史读取/导出不另设更小的源码大小门槛；全部文件通过 ArtifactArchive 生成标准无压缩 UTF-8 ZIP，保留相对目录、CRC32 和中央目录，无 Shell/第三方压缩依赖。

HTML/MD/TXT 可导出 PDF；Markdown/TXT 复用 ArtifactTextRendering 转换，HTML 保持关联资源。源文件在 workspaces/exports 的唯一暂存目录中生成，独立 WebPageContainer 通过受控根渲染，导出不占用/重载作品窗口。单次导出 worker、零等待队列；分享完成清理，取消加入 worker 并清理，根关闭取消/加入，首次导出回收上次进程残留。分享文件保留到系统分享关闭；容量、渲染和清理错误显式反馈。PDF 静态导出，不承诺保存动画状态。

ArtifactService 只拥有作品业务，不提供历史 startNew/delete/title 命令。Writer 长期任务与对话读取由 Agents/Writer 和 Storage 的委托记录接口管理。

工作区 start 在模型获取前显示准备占位或已有内容，并返回窗口身份；占位不写入项目草稿、不视为完成渲染。展示失败撤销内存会话与写锁，保留已落盘草稿。

内部 start 为新委托恢复窗口，resume 为同任务续作保留关闭/最小化偏好；两者均非 Writer 模型可选择的编辑命令。Assistant 显式打开作品也恢复最小化窗口。

任务文件预览使用独立暂存快照与 UI 受控 WebPageContainer，本地资源根、网络阻断和导航策略保持一致。预览和导出各仅一个 worker、零等待队列；根关闭取消并加入，预览离页请求取消并清理。首次临时目录清理由共用的准备任务合并，不能在首次导出时删除正在展示的预览。SVG 使用 HTML 宿主渲染；CSS/JS/JSON 转义显示并可作为文本 PDF 导出。分享关闭才清理对应导出文件。

新项目的首次checkpoint在模型开始前建立agent/task_N目录；续作直接修改当前文件。SQL写租约排除并发写者，单文件原子替换后提交索引；失败保留真实文件和草稿状态，后续读取校验索引，不从模型日志恢复代码。

start 的 createWorkspace 参数由受信 Writer 运行时为未完成初始化的预留项目传入，不暴露给模型工具 schema；模型循环不允许 start/resume。已有就绪项目缺失保持 missingProject。预览与 PDF 的临时 HTML 使用与发布一致的 UTF-8 BOM，源文件导出保持原始 UTF-8 文本。

工具失败区分 invalidReadRange、readReferenceLimit、relatedContextLimit、savepointLimit、invalidTitle 与 invalidQuery，并附具体修正范围；不将参数错误或读取引用数量解释为作品磁盘不足。窗口并发不足仍明确 busy。

ZIP 导出依据标准 ZIP 的字段宽度预检条目数、源码字节和偏移；需要 ZIP64 时明确 archiveFormatLimit，建议导出单文件，不产生整数转换崩溃或截断档案。此边界只约束该导出格式，不约束模型生成/文件编写。

局部编辑 context 明确选区是否以换行开始/结束；内容作者应在非空替换中保留这些分隔符，避免相邻行被合并。宿主不猜测源码、不自动插入换行，原子替换仍只覆盖读取引用选区。

replace使用fresh read引用约束字面旧文本，唯一匹配后原子替换为新文本，保留选区外及选区内未匹配部分；无匹配/多匹配明确ambiguousMatch，过期/跨文件引用readRequired。空新文本删除匹配，禁止空旧文本。成功修改失效该文件引用、保存草稿并清除render状态；引用/匹配校验失败不改变草稿，不修改当前文件；后续Storage检查点失败明确传播，不伪装保存成功。操作完全使用StorageFiles和内存字符串，不执行shell。

连续呈现以每项目 previews/<workspaceID> 作为稳定 WebKit 读取根，两个快照槽各保存一个唯一版本子目录，另保留一个稳定 preview.html 宿主文件直到项目关闭；相对资源使用新版本 URL，避免复用过期 CSS/图片缓存。只回收非当前槽，不因版本变化更换原生页面。preview 调用 UI 的同文档增量能力，完整 render 调用保留视口的本地导航；新页面/安全域仍由 UI 隔离。取消及项目锁继续覆盖写入、呈现和清理，关闭作品不重开窗口。

## 标题、副标题与后台快照

会话标题在start接纳，首个edit的可选title随后续文件检查点保存；rename独立持久化标题，续作沿用。describe为Writer运行时更新操作subtitle，不改源码或模型上下文。ArtifactPresentation将这些通用显示值提交WindowState；重名仅在活动窗口显示层加稳定创建顺序后缀，业务标题不带序号。

每项目最多一份latest快照，最多四项目；Scene隐藏不创建窗口/写预览资源/调用WebKit，返回deferred并保留最新文件。显式render可留下deferred验证证据供finish保存，不能宣称视觉检查通过。前台恢复经项目锁重新读取最新快照，避免排队旧副本覆盖新文件或名称；关闭/删除已退休的快照不复活，最小化不恢复。恢复和元信息更新不经Gateway，因为属于Action容器内部。

窗口身份在等待首次呈现前预留并绑定，切后台导致回执中断时保留同一窗口，不按标题猜测归属。正在渲染时隐藏转换为deferred，截图不可见返回nil；其他渲染/磁盘错误仍明确传播。UI窗口生命周期与Writer执行独立。后台CPU/进程存活由系统控制，本能力不伪造后台运行权限。

## Workspace and editing identities



Assistant library open/delete accepts executor + taskID and derives WorkspaceID; inventory includes owner/task/title/entry/state. Runtime-only workspaceID remains a deterministic compound value for Writer setup and UI file previews, not another allocated identity.

## Current workspace persistence

ArtifactWorkspace validates formats and delegates current-directory storage to StorageDatabase.WorkspaceStore.
The neutral repository indexes files in shared SQLite; source bytes live only in StorageFiles at
agent/task_N/relative-path. Checkpoints replace current files, and finish marks the current content
accepted after rendering. No historical version catalogue or restore-version tool exists. The UUID
current token fences stale publication; it is not a retained version. Temporary editor savepoints are
in-memory undo state for one active session. Web/render/export snapshots remain separately owned,
short-lived copies and never create workspace history. Missing files fail explicitly. Active task deletion
requires Writer cancellation/join before directory cleanup and metadata deletion.
