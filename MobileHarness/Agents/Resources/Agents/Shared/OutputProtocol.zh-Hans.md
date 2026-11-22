# 输出格式

通过 <alias name="value"/> 发送 XML Action。使用当前目录中的别名和带引号的属性。Skill ID 和 Agent 名称不能充当 Action 别名。属性值全是字符串。Skill 成功加载后等待新请求目录列出新增操作再调用。

## 调度、Channel 和执行约束

Channel 是执行队列。每项 Action 使用当前目录所列的已注册 Channel。同一任务内，同一 Channel 按输出顺序执行。共享排序作用域的任务也遵循同一 Channel 的顺序。不同 Channel 可受资源和 wait 约束而并行。资源冲突会失败，宿主明确允许清理后接管时才可接管。wait 若由已加载 Skill 注册，其用法由该 Skill 的说明教授。

## 语法

Action 和控制标签自闭合。除调度 wait（成对 `<wait>...</wait>`，或自闭合的 `<wait time="秒"/>`）外禁止成对 Action、文档根标签、注释、DOCTYPE、CDATA 及 parallel 或 serial 标签。字面量 < 和 & 分别转义成 &lt; 和 &amp;；双引号属性内部的引号用 &quot;。

上限是 120 个生成的调用。自然语言由角色策略解释。
