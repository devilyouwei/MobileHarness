## Expression interaction
### Scope and flow
Use eye expressions to accompany conversation or satisfy a user's expression request. express is transient; setExpression is sustained. Select only catalog values. closed closes both eyelids smoothly; clear restores the active listening neutral pose. While listening is off, the eyes rest closed and nonclosed finite performances are unavailable. Expression changes are optional in ordinary conversation and need no Task.
Text/expression may run together; use Core's wait rules for requested speech-first ordering. Avoid distracting repetition. Report actual failure rather than claim success or retry automatically. This Skill does not operate camera or arm.
### Examples
“Smile.” <express emotion="happy"/>.
“Say hello, then smile.” <wait>Hello.</wait><express emotion="happy"/>.

“Close your eyes.” <setExpression emotion="closed"/>.
“Close your eyes briefly.” <express emotion="closed"/>.

### Continuous performances
For “in order, one by one, or show them all”, use Core serial groups in one response; no new Task. Use express to await performance/restoration; setExpression only commits a base target. Follow the user's subset/order; “all” covers current express values once, excluding clear.
Serial steps, e.g. “Smile, think, and look happy in order, without speaking”:
```xml
<wait><express emotion="smile"/></wait>
<wait><express emotion="thinking"/></wait>
<wait><express emotion="happy"/></wait>
```
For “Show each expression in order and say its name”, put each expression and its speech in ONE wait, keeping default Display/Speech Channels. They may overlap; BOTH finish before the next group. Do not put all items in one wait or move speech to Display. Exact simultaneous onset is not guaranteed. Emit the requested performance without extra opening/closing narration:
```xml
<wait><express emotion="closed"/>Eyes closed.</wait>
<wait><express emotion="smile"/>Smiling.</wait>
<wait><express emotion="happy"/>Happy.</wait>
<wait><express emotion="laugh"/>Laughing.</wait>
<wait><express emotion="thinking"/>Thinking.</wait>
<wait><express emotion="surprised"/>Surprised.</wait>
<wait><express emotion="sad"/>Sad.</wait>
<wait><express emotion="love"/>Love.</wait>
<wait><express emotion="angry"/>Angry.</wait>
<wait><express emotion="scared"/>Scared.</wait>
<wait><express emotion="playful"/>Playful.</wait>
```

### Workflow boundaries
This Skill exposes only express and setExpression. Listening activation, halo, haptics, cues, transient notices and photo-departure feedback are application-owned effects; do not invent tags for them or replay them around expressions. Natural reply text is already spoken/displayed by the host.

ui.home.expression.value describes base, effective display target, overridden, transitioning and loading. Effective is the current presentation target; only the existing animation completion contract proves a transition completed. Reading or loading this Skill never changes expression.
