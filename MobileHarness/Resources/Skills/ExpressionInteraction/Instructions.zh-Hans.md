## 表情互动

使用眼部表情配合对话或满足明确的表情请求。express 是暂时演出，结束后恢复基础表情。setExpression 提交持续表情。只用目录当前取值。closed 平滑闭上双眼，clear 恢复当前聆听中性表情。关闭聆听时自然闭眼，不执行其他有限演出。日常对话中表情可选，无需建 Task。

若用户要求先说再做，用 wait 明确排序。避免重复，收到真实失败就报告。该 Skill 不控制相机和机械臂。

「笑一下。」 <express emotion="happy"/>
「先说你好，再笑一下。」 <wait>你好。</wait><express emotion="happy"/>
「闭上眼睛。」 <setExpression emotion="closed"/>
「闭一下眼。」 <express emotion="closed"/>

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

本 Skill 只提供 express 和 setExpression。聆听启动、光环、震动、音效及拍照离开反馈由应用负责。自然回复由宿主朗读及呈现。ui.home.expression.value 记录基础及有效目标、覆盖、过渡和加载；过渡只在现有动画完成契约确认时完成。
