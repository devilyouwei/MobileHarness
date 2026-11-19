# 模块归属与工程回归修复

## 范围

跨模块测试跟随发起工作流的业务所有者；App 只保留生产装配、宿主生命周期和应用级接线回归。模型/提示词效果矩阵仍归 experiments。

- 将 ChannelScheduler 契约迁到既有 Tests/Gateway/Output；WriterWorkflow 迁到 Tests/Agents/Writer，保持编译 target 不变。
- 从 PlatformContainerTests 拆出 ApplicationContainer 根注册和 UI 生命周期组合测试到既有 Tests/App/Composition；保留原 target。
- 修复 AppWorkflow target 未安装生产 Action 声明的夹具，更新退役文案与模型列表断言。等待使用显式信号、有限期限与失败清理；定位 tracking/sound 的契约变化，不以删断言或放宽生产期限换通过。
- 为 iOS 生产 ServiceFactories/ModuleRegistration/AppComposition 增加隔离目录的装配验收：实际启动、基础根一致性、一次无模型 UI 请求、前后台与停止。复用当前 Simulator App 编译边界；显式独立入口，默认产品不执行验收。现有 Assistant/Writer 确定性链路及少量真实模型 smoke 各自验证业务与模型通信，不用实验矩阵代替工程测试。
- 更新 Tests 导航、受影响目录 README、生产装配设计与验证记录。静态/格式、专项测试、全量 check.sh 和 build-ios.sh 分别记录；不自动读取真实凭据或调用付费模型。

不新增目录或生产模块。新增测试/验收文件加入现有构建成员，保留所有原用例。

## 定位补充

SoundSource 的旧等待把六次原生输入等同于六个 VAD 包，实际生产已按有界切片传递。改为断言六帧的总采样量，保留慢订阅者未释放时新方向仍能到达的原契约。Decision、机器人链路和 tracking 的截止时间回归移入既有 LiveRuntimeTests 串行阶段，不放宽生产期限。

生产装配使用 Simulator 条件入口直接编译原 App 源码，ServiceFactories 接受隔离存储根；AppComposition 首次/替换使用同一注入工厂，并提供加入替换后的 stop。正常默认参数保持原行为。验收不启用模型 smoke；模型/设备效果仍通过各自显式入口运行。

## 完成记录

已完成上述目录归位、夹具/断言/等待修复及生产装配验收。2106个原 @Test 声明保留；全量 check、四项最终迁移回归、独立 Simulator 运行和五个普通 Simulator 构建通过。详细结果及首次负载干扰记录见 [验证记录](../validation/Module-Test-Repairs.md)。
