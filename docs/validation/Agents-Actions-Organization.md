# Agents / Actions 组织与解耦验证

验证日期：2026-10-23。当前技术契约由源码 README 拥有，本文保存本次组织整理的验证与限制。

## 范围与环境

Actions 按业务能力聚合目录，收缩 Support、分开函数入口／契约／绑定／执行，显式组合 UI、语音、相机和 Task 端点。Agents 将具体装配归根级，角色解释自己的私有输入，共享机制保留通用准入、上下文与结果屏障。原有工作区改动在其当前内容上继续维护，没有创建提交或改写 Git 历史。

使用本机 Xcode 工具链，Apple Swift 6.4，macOS arm64。基础模块和编译目标不变，没有增加第三方依赖。

## 静态与行为验证

| 项目 | 结果与范围 |
| --- | --- |
| 源码／依赖边界 | 通过。包括基础模块独立、单一源码归属、角色私有协议不进入共享机制、业务端点不混入 UI 呈现、显式能力注入。 |
| Actions 地址 | 整理前后 72 项宏声明的 domain/module/function 集合一致；显式构造的地址集合也一致。注册与角色覆盖另由行为回归验证。 |
| README 与导航 | Actions、Agents 全部代码目录有 README，相对文件链接有效；153 个 Actions 和 131 个 Agents Swift 文件均有实际导航引用，无失效引用、无 App Sources 重复编译。 |
| 新增 Actions 回归 | 相机原始回执／错误与会话准入、Task 原始失败与身份准入、显式 Task 能力、端点原子绑定及旧所有者解绑隔离均通过。 |
| 新增 Agents 回归 | 未授权输入不能触发固定任务载荷解码；转交保留因果元数据。普通 Chat Context 不解释 Assistant 私有协议，Assistant 显式提供该协议。 |
| 宿主取消 | Action 和原生 Tool 的真实 Gateway 执行回归通过，取消加入已接纳工作，不等待新轮次。 |
| 完整 scripts/check.sh | 通过，最终脚本退出码为 0。包含依赖／源码边界、Python 6 项检查、全仓 Swift 格式、普通回归、独立原生／实时阶段及 plist 校验。下方保留中间失败及修正。 |

中间检查曾因重命名后的检查路径、测试导入／同名类型和行长限制失败，均已修正。角色协议改为显式注入后，合成 native-call 测试角色的宿主取消曾返回 unsupportedInput；该测试角色已显式选择 Assistant 控制钩子，并保留另一独立角色验证共享默认不解释该协议。相关宿主取消专项已重跑通过。

## iOS 编译

已尝试运行仓库的 scripts/build-ios.sh。原工程在读取 workspace 元数据时持续停于 Xcode 的 NSFileCoordinator 等待，尚未进入编译，随后停止该次等待。

为验证同一源码，使用临时隔离的工程元数据，保留相同 target ID、scheme、构建选项和锁定依赖；仅将本地 package／scheme 容器引用及 SRCROOT、PROJECT_DIR 指向原工作区。临时工程首次因 scheme 容器引用未对应隔离工程而失败；修正临时引用后，下列四项在最终源码上构建成功：

- MobileHarnessSimulator
- ModelKitRuntime
- ModelKitNemotron
- ModelKitSilero

模拟器 App 的 25 项最终 Skill 资源验证通过。CODE_SIGNING_ALLOWED=NO，未变更本地签名配置。该结果证明上述源码的模拟器编译与资源构建，不将原工程直接构建的文件协调阻塞记为成功。

## 未执行范围

未执行真实模型专项、原生页面人工验收或物理设备控制验收；自动化替身、Mac 原生运行测试和模拟器编译不能代替这些结果。未据本次目录整理宣称性能收益或物理安全验证。

交付范围：[Actions 组织与端点解耦](../completed/Actions-Organization.md)、[Agents 角色归属与共享机制](../completed/Agents-Organization.md)。
