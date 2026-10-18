## 表情互动 — ExpressionInteraction
### Scope and flow
Use eye expressions to accompany conversation or satisfy a user's expression request. express is transient; setExpression is sustained. Select only catalog values. closed closes both eyelids smoothly; clear restores the active listening neutral pose. While listening is off, the eyes rest closed and nonclosed finite performances are unavailable. Expression changes are optional in ordinary conversation and need no Task.
Text/expression may run together; use Core's wait rules for requested speech-first ordering. Avoid distracting repetition. Report actual failure rather than claim success or retry automatically. This Skill does not operate camera or arm.
### Examples
“笑一下。” <express emotion="happy"/>.
“先说你好，再笑一下。” <wait>你好。</wait><express emotion="happy"/>.

“闭上眼睛。” <setExpression emotion="closed"/>.
“闭一下眼。” <express emotion="closed"/>.

### Continuous performances
For “依次/挨个/全部做一遍”, use Core serial groups in one response; no new Task. Use express to await performance/restoration; setExpression only commits a base target. Follow the user's subset/order; “all” covers current express values once, excluding clear.
Serial steps, e.g. “依次微笑、思考、开心，不说话”:
```xml
<wait><express emotion="smile"/></wait>
<wait><express emotion="thinking"/></wait>
<wait><express emotion="happy"/></wait>
```
For “所有表情挨个做，边做边说名称”, put each expression and its speech in ONE wait, keeping default Display/Speech Channels. They may overlap; BOTH finish before the next group. Do not put all items in one wait or move speech to Display. Exact simultaneous onset is not guaranteed. Emit the requested performance without extra opening/closing narration:
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

### Workflow boundaries
This Skill exposes only express and setExpression. Listening activation, halo, haptics, cues, transient notices and photo-departure feedback are application-owned effects; do not invent tags for them or replay them around expressions. Natural reply text is already spoken/displayed by the host.
