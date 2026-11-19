# Research / Engineering 职责修正验证

日期：2026-11-18。

## 归属与入口

- 9 个 Swift 工程验证声明归 Tests/Agents：Qwen schema/评分3项、Apple 输入/解析/指标3项、Writer schema/渲染/窗口3项。原测试名称和所属编译 target 保留。
- 9 个 Python 运行器单元用例归 Tests/Agents/Assistant；新增1个 Writer 矩阵配置路径回归。与下载器8项合计18项离线用例通过。
- 4个 Decision 数值/加载器/参考夹具脚本及2份工程夹具归 Tests/ModelKit/Management/Defaults。测试制品路径相对 Models，Vela 原绝对 reference 参数改为显式 CLI。原生模型检查只使用少量参考请求，tokenizer 对照不发模型请求。
- 新增 Assistant 单输入与 Writer 单 delegate smoke，各显式选一个模型并限制最多8次请求；gate 默认关闭，凭据仅由显式环境变量提供。本次未启用真实模型、云调用或物理设备，不将未执行 smoke 描述为通过。
- Writer 模型矩阵配置移出 Datasets，scenarioFile 指向实际任务数据集；原配置失效路径已有离线回归。
- Python 5组静态 case/提示词常量、D3业务8例、二分类28例及Writer六例矩阵外置到任务 Datasets。Python常量与原AST字面值逐项核对一致。
- 从3份历史报告提取实际使用的case/request快照，报告JSON原字节不变；诊断读出仍可显式回放历史输出。实验模板归 Decision 任务目录；相册待执行人工验收步骤归 Tests/UI/Camera，报告保留未执行事实和链接。

## 静态检查

原 Swift 函数全部保留，新增2个 smoke 和1个数据加载函数。18个测试target及其依赖不变，生产target清单在排除项排序归一后相同；187份Swift源唯一归属。所有 Python 源可解析；Tests/experiments 本地 Markdown 链接通过，Xcode 358份文件引用存在且无重复。Writer配置路径可解析。历史报告JSON未修改。git diff --check通过。

## 执行检查

scripts/build-ios.sh 退出0，5个 Simulator scheme全部构建成功。完整check已编译成功。普通IntegrationTests：1200个测试，6个issue，分别为3处英文提示词断言、跟踪时序断言、Assistant Robot请求expired、photographySequenceMayExceedThirtySecondsWhenEachActionFitsItsBudget的60秒超时。后者是本轮观察到的运行失败，未声称有迁移前通过基线。搬迁后的schema/解析/评分/指标测试通过；两个新增模型smoke默认跳过。

AppWorkflow再现缺少injected Action declarations、模型列表预期和无截止等待首个模型请求的问题，仅终止卡住的测试子进程后继续串行阶段；该阶段未完整运行。串行LiveRuntimeTests为228个测试、1个soundSourceSlowSubscriberDoesNotBlockFollowingDirections声源等待超时issue；最终五个plist/project校验通过。scripts/check.sh退出1，不能记为全量通过。NativePresentationTests没有完整suite汇总，不宣称原生UI验收通过。

初次验证发现两个新Swift测试文件同名导致stringsdata产物冲突，已改为Assistant/Writer专属文件名。调整Python discovery时旧shell进程仍在读取脚本，曾出现截断命令；该次不记通过，随后以最终脚本重新执行。

本机日志：/tmp/mh-responsibilities-check.log、/tmp/mh-responsibilities-ios.log。编译/工程回归与真实模型效果、原生UI和设备验收分别报告。

重复启动的另一个check在等待SwiftPM锁、尚未执行测试时被停止；保留实际完成编译和运行的单一检查。

单独启用MH_WRITER_RENDER_EVAL后，无模型WebKit脚本刷新/点击与生产窗口宿主2项测试通过（1.160秒），命令退出0。不涉及付费模型或物理iOS验收。

最终swift test list --skip-build退出0：原2116个测试标识全部保留，仅增加两个显式gate的模型smoke，共2118个。

后续目录规则见 [实验数据职责整理](Experiment-Data-Ownership.md)：原始运行数据现归任务 Results，docs 仅保留文档及附件。以上迁移记录描述当时状态。
