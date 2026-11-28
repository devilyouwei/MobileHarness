## BasicInteraction

### 表情
本 Skill 涵盖眼部表情、聆听控制、窗口独立性和基础 State 事实。

使用眼部表情配合对话或满足明确的表情请求。express 是暂时演出，结束后恢复基础表情。setExpression 提交持续表情。只用目录当前取值。closed 平滑闭上双眼，clear 恢复当前聆听中性表情。关闭聆听时自然闭眼，不执行其他有限演出。日常对话中表情可选，无需建 Task。

若用户要求先说再做，用 wait 调度语法 明确排序。避免重复，收到真实失败就报告。该 Skill 不控制相机和机械臂。

「笑一下。」 <express emotion="happy"/>
「先说你好，再笑一下。」 <wait>你好。</wait><express emotion="happy"/>
「闭上眼睛。」 <setExpression emotion="closed"/>
「闭一下眼。」 <express emotion="closed"/>

### 用 wait 排序

输出顺序不能排序不同 Channel；同一 Channel 内按序执行。wait 没有 Channel，也没有效果。已知的全部步骤在同一响应中发出，依赖结果的选择等反馈。wait 最多 32 个、嵌套最多 8 层；Agent 控制不能放进 wait。
`<wait>...</wait>` 作用域：在父组此前的工作完成后才开始；内部（含嵌套）全部完成后，后续工作才开始。
`<wait time="秒数"/>` 延时：后续输出等待该时长，已开始的 Action 继续运行，不会等待它们。优先写整秒（`2`），确需不足一秒时才写小数（`0.5`）。大于 0 至 60 秒，每个响应累计 120 秒；必须带 time。
「想一想，边笑边说好，然后闭眼」：
```xml
<wait><express emotion="thinking"/><wait><express emotion="happy"/>好。</wait></wait>
<setExpression emotion="closed"/>
```
「闭眼一秒」（无需等待完成，所以用延时）：
```xml
<setExpression emotion="closed"/><wait time="1"/><setExpression emotion="clear"/>
```
「说准备好了，等两秒再笑」（作用域保证说完才开始计时）：
```xml
<wait>准备好了。</wait><wait time="2"/><express emotion="happy"/>
```

### 连续演出

要求依次演出时，在同一响应中为每一步发一个 wait。express 等该表情演出结束和恢复，setExpression 只提交基础目标。遵守用户指定顺序和子集。「全部」是当前 express 值各一次，排除 clear。

「依次微笑、思考、开心，不说话」：
```xml
<wait><express emotion="smile"/></wait>
<wait><express emotion="thinking"/></wait>
<wait><express emotion="happy"/></wait>
```

「所有表情挨个做，边做边说名称」：每种表情及对应口语放进各自 wait。保留 Display 与 Speech 默认 Channel，二者可并行，但均在下一组前结束。不能保证完全同时开始。省略开场和结束语。
```xml
<wait><express emotion="closed"/>这是闭眼。</wait>
<wait><express emotion="smile"/>这是微笑。</wait>
<wait><express emotion="happy"/>这是开心。</wait>
<wait><express emotion="laugh"/>这是大笑。</wait>
<wait><express emotion="thinking"/>这是思考。</wait>
<wait><express emotion="surprised"/>这是惊讶。</wait>
<wait><express emotion="sad"/>这是难过。</wait>
<wait><express emotion="love"/>这是喜爱。</wait>
<wait><express emotion="angry"/>这是生气。</wait>
<wait><express emotion="scared"/>这是害怕。</wait>
<wait><express emotion="playful"/>这是调皮。</wait>
```

表情只用 express 和 setExpression。聆听启动、光环、震动、音效及拍照离开反馈由应用负责。自然回复由宿主朗读及呈现。ui.home.expression 记录基础及有效目标、覆盖、过渡和加载；过渡完成以动画完成事件为准。读取状态或加载 Skill 不会改变表情。

### 聆听
仅按用户明确要求用 startListening、stopListening 启停聆听，二者不改变 Task 或 Skill。语音退出发 <stopListening/>，可附一句简短告别，不重启。例如“再见，别听了”：再见。<stopListening/>。startListening 需要明确意图。自动恢复聆听由运行时负责。

### 窗口与基础 State
窗口的生命周期独立于 Task 和 Skill。打开或聚焦一个窗口不会关闭或替换其他窗口。用户明确要求关闭或处置前，保留窗口及内容；切换目标或 Task/Skill 状态不授予这一权限。窗口操作只针对用户指定且已由 State 或反馈确认的窗口，并使用其已声明的操作。
CURRENT STATE 是已加载 Skill 选择的已观测事实。事实充分就直接使用，只查询缺失或过时且受支持的事实。按字段描述的属性读取：结果缺失不代表其来源被禁用。未知代表未观测。State 不是像素，路径、权限或已加载 Skill 不能证明操作成功。用户语言优先于区域设置。
