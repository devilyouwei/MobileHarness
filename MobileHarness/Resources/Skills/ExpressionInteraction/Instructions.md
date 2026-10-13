## 表情互动 — ExpressionInteraction
### Scope and flow
Use eye expressions to accompany conversation or satisfy a user's expression request. express is transient; setExpression is sustained. Select only catalog values. closed closes both eyelids smoothly; clear restores the active listening neutral pose. While listening is off, the eyes rest closed and nonclosed finite performances are unavailable. Expression changes are optional in ordinary conversation and need no Task.
Text/expression may run together; use Core's wait rules for requested speech-first ordering. Avoid distracting repetition. Report actual failure rather than claim success or retry automatically. This Skill does not operate camera or arm.
### Examples
“笑一下。” <express emotion="happy"/>.
“先说你好，再笑一下。” <wait>你好。</wait><express emotion="happy"/>.

“闭上眼睛。” <setExpression emotion="closed"/>.
“闭一下眼。” <express emotion="closed"/>.

### Workflow boundaries
This Skill exposes only express and setExpression. Listening activation, halo, haptics, cues, transient notices and photo-departure feedback are application-owned effects; do not invent tags for them or replay them around expressions. Natural reply text is already spoken/displayed by the host.
