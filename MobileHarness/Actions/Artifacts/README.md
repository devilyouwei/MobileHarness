# Artifacts — 作品与版本

本目录拥有确定性文件操作、作品索引、不可变版本和可恢复草稿，不执行模型请求。ArtifactWorkspace 使用既有 StorageFiles 工作区命名空间，项目必须包含 entryPath，索引必须包含 drafts 与 pendingDeletions。支持 HTML/CSS/JS/SVG/JSON/TXT/MD；作品数、版本数、文件数和源码大小没有额外业务配额，不按累计任务数拒绝创作。Storage 现有文件/文档容量、磁盘 I/O 与路径保护仍适用；路径禁止穿越、隐藏段和符号链接。

发布先写不可变文件再 CAS 更新索引；失败清理新版本，清理失败保留双重错误。checkpoint 保存每项目最新草稿并核对基础版本，不替换已发布内容；成功发布移除对应草稿。编辑事务的所有权及流边界见 ArtifactEditing.swift。

ArtifactsModule 暴露 Artifacts.Workspace.perform；Assistant 通过 Writing 的 XML Action 调度作品管理，Writer 通过 Gateway direct 原生 Tool 编辑作品。Assistant 仅能列出、打开、删除作品；Writer 的可信 taskID 绑定编辑会话，模型参数不能更改所有者。ArtifactService 拥有单项会话准入及项目单写锁；ArtifactEditing 拥有单流、128 个按文件版本失效的读取引用和范围修改。remove 要求有效读取引用且禁止入口删除。完整文件内容通过中立 ArtifactStreaming 端口背压追加，不通过 Tool 参数。发布要求最新草稿已进行显式渲染，存在已报告的运行错误时拒绝发布；窗口不可见时显式返回不能进行视觉验证，不能把保存等同视觉验收。

ArtifactPresentation 连接 UI 页面/窗口与 StorageFiles 临时预览；每作品双缓冲目录，最多四个页面。关闭清理预览和页面、不取消 Writer，流不会重开窗口；新委托 start 或显式 open 才解除关闭标记。删除清理窗口绑定及预览。TXT 转义显示；Markdown 支持标题、引用、列表、围栏代码、强调和 HTTP(S) 链接，其余语法保留可读文本。Writer内部preview命令按ArtifactContentParser安全检查点读取当前流或草稿，由Writer自有worker决定呈现；它不证明 HTML/JavaScript 语法有效。未完成草稿禁用脚本，完整渲染由 WebKit 执行并返回诊断/截图。项目索引可列出仅有草稿的中断作品，用户可显式委托恢复。

同项目呈现通过独立串行门合并为安全磁盘/导航顺序，最多两个可取消等待者，超限显式 busy；不同项目仍可独立进行。关闭先标记页面退出，导航中断返回“草稿保留、视觉验证不可用”，再加入呈现并清理双缓冲目录；最小化期间保留最新快照供恢复时呈现。Assistant 打开/删除同样持有项目锁。

## 文件工具与修改一致性

所有操作限定在 StorageFiles.workspaces 内，不使用 Shell。目录由相对文件路径隐式形成，不保存空目录；list(path) 返回目录下文件和字节数。move/removeTree 在读取全部受影响文件后验证整个候选草稿再更新，拒绝穿越/覆盖/路径冲突；入口禁止删除，移动入口同步更新 entry，链接内容不自动改写。相对文件的新建和最后文件的删除分别形成/移除隐式目录。

read 返回内容、起始行、字符范围、文件版本和宿主引用；line/limit 选择 1...100 行，返回内容最多 2500 字符，通过 nextOffset 继续。修改文件只失效该文件引用，其他引用继续有效。edit 的 contextReferences 最多八项、合计 24KB；宿主校验版本后装配关联片段，不接受模型伪造来源。字符 start/end 可进一步缩小已读取范围。参数数值解析失败明确拒绝。

search 支持字面匹配和路径前缀过滤，每页16项，行片段120字符，返回总数、nextOffset 及片段截断标记。savepoint 每个活动编辑会话最多八项，保存完整草稿与入口；暂停、追问或释放会话后不保留这些临时撤销点，持久草稿与已发布历史独立保留；restore 恢复草稿并失效变化文件引用。diff 返回相对 savepoint 的分页前后片段（每页两文件、各300字符），注明截断。编辑完成返回变化路径、首个变化行和字节数。versions/restoreVersion 通过受控 Storage 分页读取保留版本；历史版本的文件快照不保存入口元数据，若入口已改名，调用者需提供对应 entry。恢复只改变草稿，发布产生新版本，不覆盖历史。

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

新项目的首次 checkpoint 在模型开始前通过 DiskFileStore.directory 建立项目 UUID 根；索引提交失败清理新根，保留原始与清理错误。续作复用已绑定项目目录，版本文件保持原不可变布局。

start 的 createProject 参数由受信 Writer 运行时为未完成初始化的预留项目传入，不暴露给模型工具 schema；模型循环不允许 start/resume。已有就绪项目缺失保持 missingProject。预览与 PDF 的临时 HTML 使用与发布一致的 UTF-8 BOM，源文件导出保持原始 UTF-8 文本。

工具失败区分 invalidReadRange、readReferenceLimit、relatedContextLimit、savepointLimit、invalidTitle 与 invalidQuery，并附具体修正范围；不将参数错误或读取引用数量解释为作品磁盘不足。窗口并发不足仍明确 busy。

ZIP 导出依据标准 ZIP 的字段宽度预检条目数、源码字节和偏移；需要 ZIP64 时明确 archiveFormatLimit，建议导出单文件，不产生整数转换崩溃或截断档案。此边界只约束该导出格式，不约束模型生成/文件编写。

局部编辑 context 明确选区是否以换行开始/结束；内容作者应在非空替换中保留这些分隔符，避免相邻行被合并。宿主不猜测源码、不自动插入换行，原子替换仍只覆盖读取引用选区。

replace使用fresh read引用约束字面旧文本，唯一匹配后原子替换为新文本，保留选区外及选区内未匹配部分；无匹配/多匹配明确ambiguousMatch，过期/跨文件引用readRequired。空新文本删除匹配，禁止空旧文本。成功修改失效该文件引用、保存草稿并清除render状态；引用/匹配校验失败不改变草稿，不发布版本；后续Storage检查点失败明确传播，不伪装保存成功。操作完全使用StorageFiles和内存字符串，不执行shell。
