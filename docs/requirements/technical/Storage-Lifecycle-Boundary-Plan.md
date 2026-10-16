# Storage 与 App 生命周期边界收敛

当前接口已由 [Storage 四类容器计划](Storage-Containers-Plan.md) 演进；下文保留上轮实施与验证范围，旧名称不再作为当前 API。

状态：✅ 实现与专项回归完成；❌ 全量集成测试和 Simulator 构建尚未全部通过，实际限制见下文。用户已批准，本轮不调整其他模块，不新增目录或编译目标。

## 上轮交付记录：接口与所有权

App 选择 SQLite 后端和路径，持有 StorageRuntime，注册 storage → agents → native。既有 StorageSQLite 目标内增加运行入口及仅暴露领域协议的 StorageRepositories。Agents/Actions 通过提供器获取仓库，不依赖后端或查询 App 容器。

构造无数据库效果。start 拥有后台任务，创建目录、打开/迁移、恢复未完成事实，成功才发布仓库。重复启动加入同一结果，失败或关闭不重开，重试创建新实例。启动取消必须加入真实初始化，原始及清理错误均保留。

stop 关闭访问及后端接纳，取消并加入启动，等待在途读写，再关闭池；重复停止加入同一结果。业务拥有者先停止并提交终态；后台不关闭存储。旧仓库引用也受关闭门约束。最多 64 个读写操作，写入仍最多 17 个，超限 busy。文件/音频独立作用域、记录格式和恢复规则不变。

## 上轮实施与验证

先更新拥有者 README，再实现运行入口、后端停止屏障、延迟注入和 App 注册，清除 App 中的恢复及空停止。覆盖构造、重复启停、恢复、失败/取消、部分启动回滚、在途加入、旧引用拒绝、媒体延迟解析及关闭结果保留。执行 scripts/check.sh，完整 Xcode 下执行 scripts/build-ios.sh；自动化、构建和真实设备验收分别报告。

启动失败或取消后立即关闭仓库接纳，并保留首次失败供重复 start 返回；stop 仍必须加入初始化和后端清理。即使取消发生在后台初始化完成与调用方返回之间，也不能复用该作用域。

## 实现与验收对账

- ✅ StorageSQLite 内实现 SQLiteStorageFactory / StorageRuntime / StorageRepositories，现有目标与目录复用；业务消费者只得到延迟领域协议。
- ✅ App 清除 SQLiteRepositories、目录创建及 recoverInFlight，注册真实 storage.start/stop 与 storage → agents → native。
- ✅ 后台初始化、失败/取消后的接纳关闭、重复启停、在途读写加入、显式连接关闭、旧引用拒绝、原始及清理错误保留已实现；记录格式与恢复规则未变。
- ✅ 新增 12 项 Storage 生命周期回归通过；SQLite 与相关故障复查共 42 项通过。iOS 设备目标未签名构建与 25 项资源校验通过。
- ❌ 全量 IntegrationTests 的 880 项运行有 10 项失败、22 个 issue，涉及声源、视觉与机械臂计时；抽取的三项失败复查通过，不能据此改判全量通过。Simulator 构建仍缺外部 CoreAI 模块；后续 scheme 未执行。
- 本轮不安装真机、不执行真实模型/原生 UI/物理设备验收。详细命令、环境和日志见 [验证记录](../../validation/Validation-History.md)。
