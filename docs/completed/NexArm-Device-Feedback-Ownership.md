# NexArm 通用设备反馈与连接错误归属

用户边界：与具体动作或业务无关的配置、限制、允许误差、通用能力和硬件连接事实/错误归 PlatformKit。保持现有行为与数值，不安装、不执行实物动作。

## 代码前计划

- 在现有 PlatformKit/Connectivity/NexArm/NexArmMotorCommands.swift 内接收通用电机容差/行程估算 NexArmMotorProfiles、反馈配置 NexArmFeedbackConfiguration、无副作用位置观察器 NexArmPositionObservation。保持16/20/56/32/16/24容差、稳定2刻度、新鲜反馈及超时优先级；配置非法时抛SDK invalidMotion。
- Actions/Support 的 NexArmMotorProfiles.swift 仅保留动作 Step 参数解析；NexArmMotorExecution.swift 的完成配置改为兼容类型别名；Motion/NexArmMotionPlan.swift 的观察器改为兼容类型别名。无双份算法。动作计划、资源、报告、归位和执行生命周期不下沉。
- SDK NexArmBluetooth.swift 拥有重连预算、指数退避、原生错误重试分类及重连失败类型。Actions/Connection/BluetoothRecovery.swift 保留存储错误排除、原因展示和中文错误文案。NexArmControlService 引用SDK预算和错误，仍负责已记住设备/显式停止/业务执行协调；原生连接断开与隔离本已由SDK执行，不新增后台重连worker。
- 同步 PlatformKit、Connectivity/NexArm、Actions/NexArm/Support/Motion/Connection、总体设计与测试README。基础模块不导入项目模块，不含本地化展示或动作概念；保留原依赖边界检查。
- 增加只用SDK能力的容差边界/非法配置/过时反馈测试及原生恢复分类/退避界限测试；运行 scripts/check.sh、scripts/build-ios.sh、diff与文档链接检查。

## 完成记录（2026-10-27）

迁移与验证完成。通用定义和算法在SDK只有一份，Actions保留完成配置/观察器/重连错误的兼容别名；SDK配置非法返回原生invalidMotion，展示适配保持中文信息。新增3项SDK测试覆盖六轴容差内外边界、非法配置原生错误及恢复分类/退避边界。

scripts/check.sh退出0，普通集成分组报告885项、运行时分组报告221项，依赖/架构/格式/Python/其他Swift包/plist检查通过；可选真实模型/服务与实物测试按开关跳过。scripts/build-ios.sh退出0，四scheme及25项Skill资源校验通过。diff格式及24份受影响文档本地链接检查通过。

日志：/tmp/mh-device-feedback-check.log、/tmp/mh-device-feedback-ios.log；详见[验证历史](../validation/Validation-History.md)。未安装手机或驱动机械臂，手机仍为2026102702；物理到位不以软件测试替代。
