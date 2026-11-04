# Writer 回合完成汇报与共享窗口可见性
日期：2026-11-04。需求见Writer-Agent-Plan.md的回合修正章节。本报告不替换之前按请求开始广播的历史验收。

## 实现
请求开始只更新Writer本域Island及SQLite模型请求身份。控制响应确定编辑范围后汇报准备结果，再进入内容模型；内容提交与父工具结果checkpoint后，加入最新预览并汇报文件步骤。普通控制轮在工具效果后汇报；一个请求身份不重复，末轮由终态汇报。源码流仍由独立750ms worker更新，回合边界只加入现有变化，无变化不重载。取消不发送迟到完成步骤。

WindowState原本就是跨创建者的唯一全窗口owner；问题在于默认BasicSkill未选择ui.windows、Web源未列子会话、Web查询只能读根浏览页。BasicSkill现在默认声明窗口摘要，ui.web被动列出windowID/页面摘要；inspect/snapshot/navigate接受windowID，真实选中既有Writer session，不创建或重开。元数据适配现有每来源8KiB观察边界，完整文字/URL由显式Action读取。源文件/私有Agent上下文不共享，Assistant仍只生成调度XML Actions。

所有8个Skill介绍说明触发场景与边界。Basic/Assistant指令明确“未加载能力先加载”，窗口摘要不代表已经看过正文或像素。web-browsing负责读/截图，application-control负责通用窗口控制，writing负责已保存作品。

## 真机慢请求的只读证据
本轮复制base SQLite并immutable读取。task_9为原始简单流程图，18:30:04.402接纳，18:32:22.049取消，约137.65秒。首个控制请求18:30:04.860，内容请求18:31:02.320，前段约57.46秒；随后内容请求持续约79.73秒到取消。模型记录为qwen3.8-max，首控制用量generated2444、input2169；内容请求终态cancelled，未形成完成记录。说明可观察到的长等待包含模型请求阶段，不能把它等同Window调度卡死。

task_10为新的Transformer架构图目标，base保留首控制请求generating。WAL约3.2MB、复制再次CoreDevice7000/POSIX60失败，无法推断最新轮次、是否已经完成或实际首包时刻。base不是原子实时快照，不把旧状态当作当前卡住的证明。本轮没有清空、终止或覆盖设备任务；临时副本调查后删除。

此前真实模型矩阵中Qwen内容首事件148.56秒，见Writer-Continuous-Progress.md；本次结构修正不等于消除了Provider首包/思考等待，Writer thinking配置不变。

## 自动化与真实模型
定向回归已通过：默认Assistant在未加载窗口Skill时通过真实公开reader看到artifact窗口；加载后XML绑定可解析指定windowID。Web路由替身验证两个Writer窗口的正文/截图隔离、实际回执ID、本地路径隐藏、无根页面读写/额外窗口、错误ID拒绝。真实macOS WebKit加载两页后可被动观察标题与UUID，移除后消失。本机Writer/Gateway/SQLite 12个替身流程通过，包括拒收Assistant报告、源流预览与正常发布。

回合顺序测试覆盖控制1→编辑范围准备→预览屏障/完成汇报1→内容2→追加/提交→屏障/汇报2→控制3/render→屏障/汇报3→控制4/finish。已准备编辑不声称文件完成，最后一轮不重复普通汇报。

受控Qwen首次运行在模型调用前因旧夹具缺agents.writer来源而missing，0/2，未发生Provider请求。补齐显式夹具后重跑（不改变生产resolver），sourceUnchanged=true、exit0、2/2：
- “看看Writer画的那个窗口里写了什么文字”：5.503秒，3次模型请求，先loadSkills(web-browsing)，再Web.inspect(actual windowID)。
- “把Writer的流程图窗口放大”：2.959秒，2次模型请求，先loadSkills(application-control)，再Window.maximize(actual windowID)。

使用.env.local中阿里兼容端点，未使用OpenAI凭据。实际执行生产Assistant、Gateway/XML/Skill工作流；窗口/页面反馈为明确替身，不代表iOS原生截图或真人语音。模型结果及源码哈希见Writer-Round-Window-Model.json，原始证据/tmp/writer-window-model-final-qwen3.8-max.json。前次失败保留/tmp/writer-shared-window-model.summary.json。

## 推理模式对照
同一原始简单图目标，使用生产Writer/Gateway/Storage和真实macOS WebKit，新增仅评估的minimum模式（Qwen的Provider参数关闭thinking），未改生产设置：
| 模式/样本 | 请求数 | 首个有效画面 | 总耗时 | 内容请求首事件 / 总时长 |
| --- | ---: | ---: | ---: | ---: |
| 前次enabled | 4 | 197.29秒 | 229.59秒 | 148.56 / 183.02秒 |
| 本次minimum | 4 | 12.94秒 | 47.04秒 | 0.552 / 40.925秒 |
两次源码约6.0KB/5.7KB，均发布并通过结构/标签/实际WebKit检查；没有跳过必要render或增加输出限制。这个单例对照支持推理模式是明显延迟因素，不保证所有请求相同比例提速，也不是手机端实测延迟。用户依据对照确认优先速度；新版本Writer默认minimum，并新增可显式开启的深度思考开关，当前执行的租约保持原配置。
minimum实验sourceUnchanged/binaryUnchanged=true、exit0、diagram1/1，结果/轨迹见Writer-Round-Minimum.json与Writer-Round-Minimum-Requests.json。完整临时记录/tmp/writer-round-minimum-qwen3.8-max。

## 完整验证与交付
回合/窗口修正后的完整check exit0（/tmp/writer-round-window-check-final.log），iOS四目标构建exit0（/tmp/writer-round-window-ios-latest.log）。随后按用户确认新增Writer低思考默认与可选开关，最新iOS四目标构建exit0（/tmp/writer-thinking-ios.log），配置持久/重开/回滚、草稿保存、模型选择隔离定向测试通过（/tmp/writer-thinking-tests-final.log）。用户确认后的最新完整check exit0（/tmp/writer-thinking-check.log），包括1013项主体与225项原生运行时测试，架构边界、格式和plist校验通过。真机调查使用此前版本，本轮代码尚未安装，未声称新版本原生语音/窗口体验通过。

完整检查首轮发现：windowID宏参数默认必填使根浏览示例拒绝，新增文案超出base提示/三Skill预算，以及两处旧State集合断言。参数改为显式optional；压缩重复教学后base25869、photography37509、web32977字节，保持原预算；三Skill共存与全部Web示例解析已通过。未扩大预算或删除核心功能。

共享页面并发补验：新导航取消旧JS读取/截图，避免读操作占槽让Writer渲染busy；真实macOS WebKit有界慢DOM getter测试通过，旧读取CancellationError、新页面Updated。首次测试因注入脚本返回DOM对象无法桥接失败，修正测试脚本返回Bool后通过，产品不做猜测型处理。

Writer深度思考选择通过UI→ApplicationControl/Gateway→Provider设置事务保存，缺省表示默认minimum，不增加旧版本分支、存储迁移或SQLite清空；新建/续作委托采用新值，当前任务及其恢复租约保持快照。Assistant仍minimum，Provider/模型/凭据选择不变。

最终交付：Provider writerThinking默认false；智能体大脑Writer云端区可显式开启。保存/还原/失败回滚与重开均已验证，原有三Skill共存及提示预算未扩大。最新代码未更新真机，不把此前版本的设备测试当作本轮新功能验收。没有提交commit、清空SQLite或增加模型输出/生产总轮数限制。
