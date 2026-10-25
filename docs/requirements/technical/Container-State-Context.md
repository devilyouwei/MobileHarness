# Container 状态与模型上下文

状态：代码已实现，完整检查及四方案iOS构建通过；真实模型与真机验收待执行。

目标：移除 StorageState；状态由能力／业务 Container 内存拥有，Agent 持有只读来源注册表。Skill v3声明 useActions／useStates／useInstructions。Task与Skill保持Agent私有，不建立公开镜像。导航覆盖路径、详情、弹层及加载／操作状态。

验收：上下文每次请求刷新、权限不变、来源生命周期与容量失败明确、四基础模块无互引；旧State目标及运行引用清零；执行check及iOS构建，真机与真实模型验收单独记录。

验证证据与未执行范围见[专项记录](../../validation/Container-State-Context.md)。
