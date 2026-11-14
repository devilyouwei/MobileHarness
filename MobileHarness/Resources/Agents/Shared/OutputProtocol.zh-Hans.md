# 输出格式

通过 <alias name="value"/> 发送 XML Action。使用当前目录中的别名和带引号的属性。Skill ID 和 Agent 名称不能充当 Action 别名。属性值全是字符串。Skill 成功加载后等待新请求目录列出新增操作再调用。

## 调度、Channel 和 wait

Channel 是执行队列。每项 Action 使用当前目录所列的已注册 Channel。同一任务内，同一 Channel 按输出顺序执行。共享排序作用域的任务也遵循同一 Channel 的顺序。不同 Channel 可受资源和 wait 约束而并行。资源冲突会失败，宿主明确允许清理后接管时才可接管。

<wait>...</wait> 等待父组在它之前的工作完成才开始，并在自身闭合及内部工作全部完成以前阻止父组后续工作。组内按 Channel 排序。隐式根组和嵌套组均不等待自身、祖先或其他任务。空的 <wait></wait> 有效。

## 连续操作

在一个响应中发送所有已知的请求步骤。依赖结果的选择等待反馈。仍须遵守独占回合约束。

严格串行 A 到 D 使用 <wait>A</wait><wait>B</wait><wait>C</wait><wait>D</wait>。即使跨 Channel，上一步也先完成。两对并行操作依次执行时使用 <wait>A B</wait><wait>C D</wait>，A/B 可在不同 Channel 重叠，两者完成后才开始 C/D。A 到 D 指已声明的 Action 或角色映射的文字。

## 语法

wait 必须成对，可嵌套且无属性。Action 标签自闭合。禁止 <wait/>、成对 Action、文档根标签、注释、DOCTYPE、CDATA 及 parallel 或 serial 标签。字面量 < 和 & 分别转义成 &lt; 和 &amp;；双引号属性内部的引号用 &quot;。

上限是 32 个 wait、8 层嵌套作用域和 120 个 Action。wait 不增加超时或回滚。自然语言由角色策略解释。
